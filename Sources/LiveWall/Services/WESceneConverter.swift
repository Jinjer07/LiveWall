import Foundation
import AppKit
import Compression
import ImageIO
import UniformTypeIdentifiers

// Конвертер сцен Wallpaper Engine (scene.pkg) в сцены LiveWall.
// Достаёт оригинальные картинки из архива, раскладывает их по слоям с параллаксом
// и подбирает похожие эффекты LiveWall. Точной копии нет: шейдеры и «кукольная» анимация WE не переносятся.

// MARK: - Чтение двоичных данных

struct BinReader {
    let data: Data
    var pos: Int = 0
    init(_ d: Data) { data = d }

    var remaining: Int { data.count - pos }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw LWError(tr("неожиданный конец файла")) }
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: data.startIndex.distance(to: data.startIndex) + pos, as: UInt32.self) }
        pos += 4
        return UInt32(littleEndian: v)
    }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else { throw LWError(tr("неожиданный конец файла")) }
        let d = data.subdata(in: data.startIndex + pos ..< data.startIndex + pos + n)
        pos += n
        return d
    }

    /// Строка с длиной в начале (uint32 + байты).
    mutating func lenString() throws -> String {
        let n = Int(try u32())
        guard n < 4096 else { throw LWError(tr("повреждённая строка")) }
        return String(decoding: try bytes(n), as: UTF8.self)
    }

    /// Строка до нулевого байта.
    mutating func cString(max: Int = 64) throws -> String {
        var out = Data()
        while remaining > 0, out.count < max {
            let b = data[data.startIndex + pos]; pos += 1
            if b == 0 { break }
            out.append(b)
        }
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: - scene.pkg

struct WEPackage {
    let files: [String: Data]

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var r = BinReader(data)
        let magic = try r.lenString()
        guard magic.hasPrefix("PKGV") else { throw LWError(tr("не PKG-архив (%@)", magic)) }
        let count = Int(try r.u32())
        var entries: [(String, Int, Int)] = []
        for _ in 0..<count {
            let name = try r.lenString()
            let off = Int(try r.u32()), len = Int(try r.u32())
            entries.append((name, off, len))
        }
        let base = r.pos
        var files: [String: Data] = [:]
        for (name, off, len) in entries {
            let s = base + off
            guard s >= 0, s + len <= data.count else { continue }
            files[name] = data.subdata(in: s ..< s + len)
        }
        self.files = files
    }

    func json(_ path: String) -> [String: Any]? {
        guard let d = files[path] else { return nil }
        return (try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])) as? [String: Any]
    }
}

// MARK: - Текстуры .tex

enum WETexture {
    struct Info {
        var format: Int32
        var flags: Int32
        var imgW: Int
        var imgH: Int
        var images: [CGImage]                                   // первый mip каждого изображения
        var frames: [(image: Int, delay: Double, rect: CGRect)] // кадры анимации (спрайт-лист)
        var isAnimated: Bool { frames.count > 1 }      // GIF или спрайт-лист
    }

    /// Декодирует .tex в CGImage (первый кадр, старший mip-уровень).
    static func decode(_ data: Data) throws -> CGImage {
        let info = try parse(data)
        if info.isAnimated, let f = info.frames.first, f.image < info.images.count {
            return info.images[f.image].cropping(to: f.rect) ?? info.images[f.image]
        }
        return info.images[0]
    }

    static func parse(_ data: Data) throws -> Info {
        var r = BinReader(data)
        let m1 = try r.cString(), m2 = try r.cString()
        guard m1.hasPrefix("TEXV"), m2.hasPrefix("TEXI") else { throw LWError(tr("не TEX (%@)", m1)) }
        let format = try r.i32()
        let flags = try r.i32()
        _ = try r.i32(); _ = try r.i32()
        let imgW = Int(try r.i32()), imgH = Int(try r.i32())
        _ = try r.u32()

        let container = try r.cString()
        guard container.hasPrefix("TEXB") else { throw LWError(tr("нет блока TEXB")) }
        let ver = Int(container.dropFirst(4)) ?? 1
        let imageCount = Int(try r.i32())
        guard imageCount > 0, imageCount < 512 else { throw LWError(tr("пустая текстура")) }
        var freeImageFormat: Int32 = -1
        if ver >= 3 { freeImageFormat = try r.i32() }
        if ver >= 4 { _ = try r.i32() }

        var images: [CGImage] = []
        for _ in 0..<imageCount {
            let mipCount = Int(try r.i32())
            guard mipCount > 0, mipCount < 32 else { throw LWError(tr("нет mip-уровней")) }
            for m in 0..<mipCount {
                let w = Int(try r.i32()), h = Int(try r.i32())
                var payload: Data
                var compressed: Int32 = 0, rawSize = 0
                if ver >= 2 {
                    compressed = try r.i32()
                    rawSize = Int(try r.i32())
                }
                let size = Int(try r.i32())
                payload = try r.bytes(size)
                guard m == 0 else { continue }
                if compressed == 1 { payload = try lz4(payload, rawSize: rawSize) }
                images.append(try image(payload, format: format, freeImageFormat: freeImageFormat, w: w, h: h, cropW: w, cropH: h))
            }
        }

        var frames: [(Int, Double, CGRect)] = []
        if r.remaining > 8, let magic = try? r.cString(), magic.hasPrefix("TEXS") {
            let sver = Int(magic.dropFirst(4)) ?? 1
            let count = Int(try r.i32())
            if sver >= 3 { _ = try r.i32(); _ = try r.i32() }
            // Числа бывают целыми или float — определяем по битовому шаблону
            func n(_ bits: UInt32) -> Double {
                let f = Float(bitPattern: bits)
                if bits != 0 && abs(f) < 1e-30 { return Double(Int32(bitPattern: bits)) }
                return Double(f)
            }
            for _ in 0..<min(count, 2000) {
                guard r.remaining >= 32 else { break }
                let img = Int(try r.i32())
                let delay = Double(Float(bitPattern: try r.u32()))
                let x = n(try r.u32()), y = n(try r.u32()), w = n(try r.u32())
                let u1 = n(try r.u32()), u2 = n(try r.u32()), h = n(try r.u32())
                let fw = abs(w) > 0 ? abs(w) : abs(u1), fh = abs(h) > 0 ? abs(h) : abs(u2)
                frames.append((img, delay > 0 && delay < 10 ? delay : 0.1,
                               CGRect(x: min(x, x + w), y: min(y, y + h), width: max(1, fw), height: max(1, fh))))
            }
        }
        // Обычная текстура: отрезаем выравнивание до степени двойки
        if frames.count <= 1 {
            images = images.map { img in
                let cw = imgW > 0 ? min(imgW, img.width) : img.width, ch = imgH > 0 ? min(imgH, img.height) : img.height
                return (cw == img.width && ch == img.height) ? img : (img.cropping(to: CGRect(x: 0, y: 0, width: cw, height: ch)) ?? img)
            }
        }
        return Info(format: format, flags: flags, imgW: imgW, imgH: imgH, images: images,
                    frames: frames.map { (image: $0.0, delay: $0.1, rect: $0.2) })
    }

    private static func image(_ payload: Data, format: Int32, freeImageFormat: Int32, w: Int, h: Int, cropW: Int, cropH: Int) throws -> CGImage {
        // Вложенный файл изображения (JPG/PNG/…)
        if freeImageFormat != -1, let src = CGImageSourceCreateWithData(payload as CFData, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return img
        }
        var rgba: [UInt8]
        switch format {
        case 0: rgba = [UInt8](payload)
        case 4: rgba = DXT.decode(payload, w: w, h: h, kind: 5)
        case 6: rgba = DXT.decode(payload, w: w, h: h, kind: 3)
        case 7: rgba = DXT.decode(payload, w: w, h: h, kind: 1)
        case 8:
            rgba = [UInt8](repeating: 0, count: w * h * 4)
            payload.withUnsafeBytes { p in
                for i in 0..<min(w * h, p.count / 2) {
                    let g = p[i * 2], a = p[i * 2 + 1]
                    rgba[i * 4] = g; rgba[i * 4 + 1] = g; rgba[i * 4 + 2] = g; rgba[i * 4 + 3] = a
                }
            }
        case 9:
            rgba = [UInt8](repeating: 255, count: w * h * 4)
            payload.withUnsafeBytes { p in
                for i in 0..<min(w * h, p.count) { let g = p[i]; rgba[i * 4] = g; rgba[i * 4 + 1] = g; rgba[i * 4 + 2] = g }
            }
        default:
            throw LWError(tr("неизвестный формат текстуры %@", format))
        }
        guard rgba.count >= w * h * 4 else { throw LWError(tr("мало данных текстуры")) }
        let cw = max(1, min(cropW > 0 ? cropW : w, w)), ch = max(1, min(cropH > 0 ? cropH : h, h))
        return try makeImage(rgba, w: w, h: h, cropW: cw, cropH: ch)
    }

    /// Собирает анимированный GIF из кадров спрайт-листа.
    static func writeGIF(_ info: Info, to url: URL, maxSide: Int = 1920) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, info.frames.count, nil) else {
            throw LWError(tr("не удалось создать GIF"))
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for f in info.frames where f.image < info.images.count {
            guard let frame = info.images[f.image].cropping(to: f.rect) else { continue }
            CGImageDestinationAddImage(dest, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: f.delay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw LWError(tr("не удалось записать GIF")) }
    }

    static func makeImage(_ rgba: [UInt8], w: Int, h: Int, cropW: Int, cropH: Int) throws -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let full = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                 space: cs, bitmapInfo: info, provider: provider, decode: nil,
                                 shouldInterpolate: true, intent: .defaultIntent) else { throw LWError(tr("не удалось собрать изображение")) }
        if cropW == w && cropH == h { return full }
        return full.cropping(to: CGRect(x: 0, y: 0, width: cropW, height: cropH)) ?? full
    }

    static func lz4(_ src: Data, rawSize: Int) throws -> Data {
        guard rawSize > 0 else { return src }
        var dst = Data(count: rawSize)
        let n = dst.withUnsafeMutableBytes { d in
            src.withUnsafeBytes { s in
                compression_decode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, rawSize,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        if n == rawSize { return dst }
        return try lz4Manual(src, rawSize: rawSize)
    }

    /// Ручная распаковка LZ4-блока (на случай, если системная отказалась).
    static func lz4Manual(_ src: Data, rawSize: Int) throws -> Data {
        let s = [UInt8](src)
        var out = [UInt8](); out.reserveCapacity(rawSize)
        var i = 0
        while i < s.count {
            let token = Int(s[i]); i += 1
            var lit = token >> 4
            if lit == 15 { while i < s.count { let b = Int(s[i]); i += 1; lit += b; if b != 255 { break } } }
            guard i + lit <= s.count else { throw LWError(tr("повреждённые данные LZ4")) }
            out.append(contentsOf: s[i ..< i + lit]); i += lit
            if i >= s.count { break }
            guard i + 1 < s.count else { break }
            let off = Int(s[i]) | Int(s[i + 1]) << 8; i += 2
            var ml = token & 15
            if ml == 15 { while i < s.count { let b = Int(s[i]); i += 1; ml += b; if b != 255 { break } } }
            ml += 4
            guard off > 0, off <= out.count else { throw LWError(tr("повреждённые данные LZ4")) }
            let start = out.count - off
            for k in 0..<ml { out.append(out[start + k]) }
        }
        return Data(out)
    }
}

// MARK: - DXT1/3/5

enum DXT {
    static func decode(_ data: Data, w: Int, h: Int, kind: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let b = [UInt8](data)
        let blockSize = kind == 1 ? 8 : 16
        let bw = (w + 3) / 4, bh = (h + 3) / 4
        var off = 0
        for by in 0..<bh {
            for bx in 0..<bw {
                guard off + blockSize <= b.count else { return out }
                var alpha = [UInt8](repeating: 255, count: 16)
                var co = off
                if kind == 3 {
                    for i in 0..<8 {
                        let v = b[off + i]
                        alpha[i * 2] = (v & 0x0F) * 17
                        alpha[i * 2 + 1] = (v >> 4) * 17
                    }
                    co = off + 8
                } else if kind == 5 {
                    let a0 = Int(b[off]), a1 = Int(b[off + 1])
                    var bits: UInt64 = 0
                    for i in 0..<6 { bits |= UInt64(b[off + 2 + i]) << (8 * UInt64(i)) }
                    var pal = [Int](repeating: 0, count: 8)
                    pal[0] = a0; pal[1] = a1
                    if a0 > a1 { for i in 1...6 { pal[i + 1] = ((7 - i) * a0 + i * a1) / 7 } }
                    else { for i in 1...4 { pal[i + 1] = ((5 - i) * a0 + i * a1) / 5 }; pal[6] = 0; pal[7] = 255 }
                    for i in 0..<16 { alpha[i] = UInt8(pal[Int((bits >> (3 * UInt64(i))) & 7)]) }
                    co = off + 8
                }
                let c0 = Int(b[co]) | Int(b[co + 1]) << 8, c1 = Int(b[co + 2]) | Int(b[co + 3]) << 8
                func rgb(_ c: Int) -> (Int, Int, Int) {
                    ((c >> 11 & 31) * 255 / 31, (c >> 5 & 63) * 255 / 63, (c & 31) * 255 / 31)
                }
                let p0 = rgb(c0), p1 = rgb(c1)
                var pal: [(Int, Int, Int, Int)] = [(p0.0, p0.1, p0.2, 255), (p1.0, p1.1, p1.2, 255)]
                if c0 > c1 || kind != 1 {
                    pal.append(((2 * p0.0 + p1.0) / 3, (2 * p0.1 + p1.1) / 3, (2 * p0.2 + p1.2) / 3, 255))
                    pal.append(((p0.0 + 2 * p1.0) / 3, (p0.1 + 2 * p1.1) / 3, (p0.2 + 2 * p1.2) / 3, 255))
                } else {
                    pal.append(((p0.0 + p1.0) / 2, (p0.1 + p1.1) / 2, (p0.2 + p1.2) / 2, 255))
                    pal.append((0, 0, 0, 0))
                }
                let idx = UInt32(b[co + 4]) | UInt32(b[co + 5]) << 8 | UInt32(b[co + 6]) << 16 | UInt32(b[co + 7]) << 24
                for py in 0..<4 {
                    for px in 0..<4 {
                        let x = bx * 4 + px, y = by * 4 + py
                        guard x < w, y < h else { continue }
                        let k = py * 4 + px
                        let c = pal[Int((idx >> (2 * UInt32(k))) & 3)]
                        let o = (y * w + x) * 4
                        out[o] = UInt8(c.0); out[o + 1] = UInt8(c.1); out[o + 2] = UInt8(c.2)
                        out[o + 3] = kind == 1 ? UInt8(c.3) : alpha[k]
                    }
                }
                off += blockSize
            }
        }
        return out
    }
}

// MARK: - Сцена WE → сцена LiveWall

enum WESceneConverter {
    struct Result {
        var doc: SceneDoc
        var images: [String: CGImage]          // имя файла → картинка
        var animated: [String: WETexture.Info] // GIF-слои
        var notes: [String]                    // что не удалось перенести
    }

    /// Источник файлов: scene.pkg или распакованная папка проекта.
    struct Source {
        let pkg: WEPackage?
        let folder: URL
        func data(_ path: String) -> Data? {
            if let d = pkg?.files[path] { return d }
            return try? Data(contentsOf: folder.appendingPathComponent(path))
        }
        func json(_ path: String) -> [String: Any]? {
            guard let d = data(path) else { return nil }
            return (try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])) as? [String: Any]
        }
    }

    static func canConvert(folder: URL) -> Bool {
        let fm = FileManager.default
        let (pkg, scene) = files(in: folder)
        return fm.fileExists(atPath: pkg.path) || fm.fileExists(atPath: folder.appendingPathComponent(scene).path)
    }

    // Значение может быть «как есть» или {"value": …, "user": …}
    private static func val(_ v: Any?) -> Any? {
        if let d = v as? [String: Any], d["value"] != nil { return d["value"] }
        return v
    }
    private static func vec(_ v: Any?) -> [Double] {
        let x = val(v)
        if let s = x as? String { return s.split(separator: " ").compactMap { Double($0) } }
        if let n = x as? NSNumber { return [n.doubleValue] }
        if let a = x as? [NSNumber] { return a.map(\.doubleValue) }
        return []
    }
    private static func num(_ v: Any?) -> Double? { vec(v).first }
    private static func bool(_ v: Any?) -> Bool? {
        let x = val(v)
        if let b = x as? Bool { return b }
        if let n = x as? NSNumber { return n.boolValue }
        return nil
    }
    private static func hex(_ c: [Double]) -> String {
        guard c.count >= 3 else { return "#ffffff" }
        func h(_ v: Double) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", h(c[0]), h(c[1]), h(c[2]))
    }

    static func files(in folder: URL) -> (pkg: URL, scene: String) {
        let project = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("project.json")))) as? [String: Any]
        let scene = project?["file"] as? String ?? "scene.json"
        let base = (scene as NSString).deletingPathExtension
        return (folder.appendingPathComponent(base + ".pkg"), scene)
    }

    static func convert(folder: URL) throws -> Result {
        let (pkgURL, sceneFile) = files(in: folder)
        let pkg = FileManager.default.fileExists(atPath: pkgURL.path) ? try WEPackage(url: pkgURL) : nil
        let src = Source(pkg: pkg, folder: folder)
        guard let scene = src.json(sceneFile) else { throw LWError(tr("в сцене нет scene.json")) }

        var notes: [String] = []
        var images: [String: CGImage] = [:]
        var animated: [String: WETexture.Info] = [:]
        let general = scene["general"] as? [String: Any] ?? [:]
        var W = 1920.0, H = 1080.0
        if let ortho = general["orthogonalprojection"] as? [String: Any] {
            if let w = num(ortho["width"]), let h = num(ortho["height"]), w > 0, h > 0 { W = w; H = h }
        }
        var doc = SceneDoc()
        doc.width = W; doc.height = H
        doc.background = hex(vec(general["clearcolor"]).isEmpty ? [0, 0, 0] : vec(general["clearcolor"]))
        var autoSize = (general["orthogonalprojection"] as? [String: Any])?["auto"] as? Bool ?? false
        if general["orthogonalprojection"] == nil { autoSize = true }
        let parallaxOn = bool(general["cameraparallax"]) ?? false
        let parallaxAmount = num(general["cameraparallaxamount"]) ?? 0.5

        let objects = scene["objects"] as? [[String: Any]] ?? []
        var texIndex = 0
        var particleIndex: [ParticlePreset: Int] = [:]   // один слой на вид частиц
        for obj in objects {
            if bool(obj["visible"]) == false { continue }
            let name = (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Layer"
            let origin = vec(obj["origin"])
            let scale = vec(obj["scale"])
            let angles = vec(obj["angles"])
            let depth = vec(obj["parallaxDepth"]).first ?? 0
            let x = (origin.count > 0 ? origin[0] : W / 2) / W
            let y = 1 - (origin.count > 1 ? origin[1] : H / 2) / H
            var parallax = parallaxOn ? min(2, depth * parallaxAmount * 2) : 0

            // Частицы
            if let particlePath = obj["particle"] as? String {
                var (l, preset) = particleLayer(name: name, path: particlePath, json: src.json(particlePath))
                if let i = particleIndex[preset] {
                    doc.layers[i].pCount = min(preset == .rain ? 700 : 400, doc.layers[i].pCount + l.pCount / 3)
                    continue
                }
                if particleIndex.count >= 3 { continue }
                l.x = x; l.y = y
                l.parallax = parallax
                particleIndex[preset] = doc.layers.count
                doc.layers.append(l)
                continue
            }

            // Текст (в WE часто это часы на скрипте)
            if let t = obj["text"] {
                let td = t as? [String: Any]
                let script = (td?["script"] as? String ?? "").lowercased()
                let value = (val(t) as? String) ?? ""
                var l = SceneLayer(name: name, kind: .text)
                if script.contains("gethours") || script.contains("date") || name.lowercased().contains("clock") || name.lowercased().contains("time") {
                    l.text = script.contains("getseconds") ? "{time:s}" : "{time}"
                } else if script.contains("weekday") || name.lowercased().contains("date") {
                    l.text = "{weekday}, {date}"
                } else {
                    l.text = value.isEmpty ? name : value
                }
                let sz = vec(obj["size"])
                let sc = scale.first ?? 1
                l.fontSize = sz.count >= 2 && sz[1] > 0 ? sz[1] * sc * 0.62 : (num(obj["pointsize"]) ?? 32) * 2 * sc
                l.fontWeight = "500"
                let c = vec(obj["color"])
                l.textColor = hex(c.isEmpty ? [1, 1, 1] : c)
                l.opacity = num(obj["alpha"]) ?? 1
                l.x = x; l.y = y
                l.parallax = parallax
                doc.layers.append(l)
                continue
            }

            // Картинки
            guard let modelPath = obj["image"] as? String else {
                if obj["sound"] != nil { notes.append(tr("звук «%@» пропущен", name)) }
                continue
            }
            // Служебные слои WE: постобработка всего экрана — пропускаем; сплошной слой — заливка
            if modelPath.hasPrefix("models/util/") {
                if modelPath.contains("solid") {
                    var l = SceneLayer(name: name, kind: .color)
                    let c = vec(obj["color"])
                    l.tint = hex(c.isEmpty ? [0, 0, 0] : c)
                    l.x = x; l.y = y; l.opacity = num(obj["alpha"]) ?? 1
                    let sz = vec(obj["size"])
                    l.width = (sz.count >= 2 ? sz[0] : W) * (scale.first ?? 1)
                    l.height = (sz.count >= 2 ? sz[1] : H) * (scale.count > 1 ? scale[1] : 1)
                    doc.layers.append(l)
                }
                continue
            }
            guard let model = src.json(modelPath) else { notes.append(tr("нет модели %@", modelPath)); continue }
            if model["puppet"] != nil { notes.append(tr("анимация персонажа в «%@» не переносится", name)) }
            guard let matPath = model["material"] as? String, let mat = src.json(matPath),
                  let pass = (mat["passes"] as? [[String: Any]])?.first,
                  let texName = (pass["textures"] as? [Any])?.first as? String else {
                notes.append(tr("нет материала у «%@»", name)); continue
            }
            let alpha = num(obj["alpha"]) ?? 1
            let color = vec(obj["color"])
            let sizeV = vec(obj["size"])

            // Встроенная белая текстура WE → цветная заливка
            guard let texData = src.data("materials/\(texName).tex") else {
                if texName.contains("white") || texName.hasPrefix("util/") {
                    var l = SceneLayer(name: name, kind: .color)
                    l.tint = hex(color.isEmpty ? [1, 1, 1] : color)
                    l.x = x; l.y = y; l.opacity = alpha
                    l.width = (sizeV.count >= 2 ? sizeV[0] : W) * (scale.first ?? 1)
                    l.height = (sizeV.count >= 2 ? sizeV[1] : H) * (scale.count > 1 ? scale[1] : 1)
                    l.parallax = parallax
                    doc.layers.append(l)
                } else {
                    notes.append(tr("встроенная текстура «%@» недоступна", texName))
                }
                continue
            }
            let img: CGImage
            do {
                let info = try WETexture.parse(texData)
                if info.isAnimated && info.flags & 4 != 0 {
                    texIndex += 1
                    let gif = String(format: "layer-%02d.gif", texIndex)
                    animated[gif] = info
                    notes.append(tr("анимированный слой «%@» сохранён как GIF", name))
                }
                img = try WETexture.decode(texData)
            } catch {
                notes.append(tr("текстура «%@»: %@", texName, error.localizedDescription)); continue
            }
            texIndex += 1
            let file = String(format: "layer-%02d.png", texIndex)
            images[file] = img

            if autoSize && doc.layers.isEmpty {
                W = Double(img.width); H = Double(img.height)
                doc.width = W; doc.height = H
            }
            var l = SceneLayer(name: name, kind: .image)
            l.file = file
            l.x = x; l.y = y
            l.opacity = alpha
            if !color.isEmpty && color != [1, 1, 1] { l.tint = hex(color) }
            let dispW = (sizeV.count >= 2 && sizeV[0] > 0 ? sizeV[0] : Double(img.width)) * (scale.first ?? 1)
            l.scale = dispW / Double(img.width)
            if let z = angles.count > 2 ? angles[2] : nil, z != 0 {
                l.rotation = abs(z) <= 2 * .pi ? -z * 180 / .pi : -z
            }
            // Фон (первый слой на весь экран) — без параллакса, но чуть крупнее, чтобы не было краёв
            if doc.layers.isEmpty && dispW >= W * 0.95 { parallax = parallaxOn ? max(parallax, 0.15) : 0 }
            l.parallax = parallax
            // Режим смешивания слоя WE (colorBlendMode) и материала
            switch Int(num(obj["colorBlendMode"]) ?? 0) {
            case 1, 2, 3, 4: l.blend = "multiply"
            case 5, 6: l.blend = "screen"
            case 7, 8, 9, 10: l.blend = "add"
            default:
                if (pass["blending"] as? String) == "additive" { l.blend = "add" }
            }
            // Световые слои-спрайты (капли, блики) — мягкие края, чтобы не было видно прямоугольников
            if (l.blend == "add" || l.blend == "screen") && dispW < W * 0.9 { l.feather = 0.25 }
            applyEffects(obj["effects"] as? [[String: Any]] ?? [], to: &l, notes: &notes)
            doc.layers.append(l)
        }
        if doc.layers.isEmpty { throw LWError(tr("в сцене не нашлось слоёв, которые можно перенести")) }
        var seen = Set<String>()
        notes = notes.filter { seen.insert($0).inserted }
        return Result(doc: doc, images: images, animated: animated, notes: notes)
    }

    private static func applyEffects(_ effects: [[String: Any]], to l: inout SceneLayer, notes: inout [String]) {
        for e in effects {
            if bool(e["visible"]) == false { continue }
            let f = (e["file"] as? String ?? "").lowercased()
            if f.contains("shake") || f.contains("wave") || f.contains("waterflow") || f.contains("ripple") || f.contains("sway") {
                l.waveEnabled = true; l.waveAmplitude = 0.35; l.waveFrequency = 3; l.waveSpeed = 1.2
            } else if f.contains("pulse") || f.contains("audio") {
                l.audioPulse = 0.08
            } else if f.contains("glow") || f.contains("bloom") || f.contains("shine") {
                l.glowEnabled = true; l.glowIntensity = 0.45; l.glowRadius = 5
            } else if f.contains("tint") || f.contains("color") {
                // цветокоррекция WE — оставляем оригинальные цвета
            } else if !f.isEmpty {
                let n = (f.split(separator: "/").dropFirst().first).map(String.init) ?? f
                if !notes.contains(where: { $0.contains(n) }) { notes.append(tr("эффект «%@» не переносится", n)) }
            }
        }
    }

    private static func particleLayer(name: String, path: String, json: [String: Any]?) -> (SceneLayer, ParticlePreset) {
        let key = (path + " " + name + " " + ((json?["material"] as? String) ?? "")).lowercased()
        let preset: ParticlePreset
        if key.contains("rain") || key.contains("drop") { preset = .rain }
        else if key.contains("snow") || key.contains("ash") { preset = .snow }
        else if key.contains("spark") || key.contains("ember") || key.contains("fire") || key.contains("flame") { preset = .sparks }
        else if key.contains("firefl") || key.contains("glow") || key.contains("light") { preset = .fireflies }
        else if key.contains("bubble") { preset = .bubbles }
        else { preset = .dust }
        var l = preset.make()
        l.name = name
        if key.contains("ash") { l.pColor = "#b9b4ae"; l.pColor2 = "#6f6a66"; l.pSpeed = 30; l.opacity = 0.8 }
        if let mc = (json?["maxcount"] as? NSNumber)?.intValue, mc > 0 {
            l.pCount = max(30, min(preset == .rain ? 600 : 300, mc))
        }
        return (l, preset)
    }

    struct Output { var type: WallpaperType; var entry: String; var notes: [String] }

    /// Конвертирует проект WE в папку LiveWall: сцену или (для GIF-сцен) анимированную картинку.
    static func convert(folder: URL, into dest: URL) throws -> Output {
        let r = try convert(folder: folder)
        let imageLayers = r.doc.layers.filter { $0.kind == .image }
        if imageLayers.count == 1, let (gifName, info) = r.animated.first {
            try WETexture.writeGIF(info, to: dest.appendingPathComponent(gifName))
            return Output(type: .image, entry: gifName, notes: r.notes.filter { !$0.contains("GIF") })
        }
        for (file, img) in r.images {
            let url = dest.appendingPathComponent(file)
            guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(d, img, nil)
            CGImageDestinationFinalize(d)
        }
        try JSONEncoder.lw.encode(r.doc).write(to: dest.appendingPathComponent("scene.json"))
        return Output(type: .scene, entry: "scene.json", notes: r.notes)
    }
}
