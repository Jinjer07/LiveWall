import Foundation
import AppKit
import SwiftUI

// MARK: - Пути

enum Paths {
    static let root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LiveWall", isDirectory: true)
    static let library = root.appendingPathComponent("Library", isDirectory: true)
    static let runtime = root.appendingPathComponent("Runtime", isDirectory: true)
    static let previews = root.appendingPathComponent("Previews", isDirectory: true)
    static let settings = root.appendingPathComponent("settings.json")
    static let state = root.appendingPathComponent("state.json")
    static let index = root.appendingPathComponent("library.json")

    static func ensure() {
        for d in [root, library, runtime, previews] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Сохранение

extension JSONEncoder {
    static var lw: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var lw: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

enum Persistence {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.lw.decode(T.self, from: d)
    }

    /// Загружает объект, подставляя значения по умолчанию для отсутствующих ключей.
    static func loadMerged<T: Codable>(_ def: T, from url: URL) -> T {
        guard let d = try? Data(contentsOf: url),
              let stored = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let defData = try? JSONEncoder.lw.encode(def),
              var base = (try? JSONSerialization.jsonObject(with: defData)) as? [String: Any]
        else { return def }
        for (k, v) in stored { base[k] = v }
        guard let merged = try? JSONSerialization.data(withJSONObject: base),
              let r = try? JSONDecoder.lw.decode(T.self, from: merged) else { return def }
        return r
    }

    static func save<T: Encodable>(_ v: T, to url: URL) {
        if let d = try? JSONEncoder.lw.encode(v) { try? d.write(to: url, options: .atomic) }
    }
}

// MARK: - Ошибки и команды

struct LWError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

enum Shell {
    @discardableResult
    static func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            throw LWError(out.isEmpty ? "Команда завершилась с кодом \(p.terminationStatus)" : out)
        }
        return out
    }
}

func jsString(_ s: String?) -> String {
    guard let s else { return "null" }
    if let d = try? JSONSerialization.data(withJSONObject: [s]), let str = String(data: d, encoding: .utf8) {
        return String(str.dropFirst().dropLast())
    }
    return "\"\""
}

extension FileManager {
    func isDirectory(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }
}

enum FileKinds {
    static let video: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv", "ogv", "avi"]
    static let image: Set<String> = ["jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "tif", "bmp"]
    static let shader: Set<String> = ["frag", "glsl", "fs", "fsh"]
    static let avPlayable: Set<String> = ["mp4", "mov", "m4v"]

    static func images(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items.filter { image.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

// MARK: - Картинки

extension NSImage {
    func jpegData(maxDimension: CGFloat = 640) -> Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let s = min(1, maxDimension / max(w, h))
        let tw = max(1, Int(w * s)), th = max(1, Int(h * s))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
}

@MainActor
enum ThumbCache {
    private static var cache: [String: NSImage] = [:]

    static func image(for url: URL?) -> NSImage? {
        guard let url else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mod = attrs[.modificationDate] as? Date else { return nil }
        let key = url.path + "#\(mod.timeIntervalSince1970)"
        if let img = cache[key] { return img }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache[key] = img
        return img
    }
}

// MARK: - Цвета

extension NSColor {
    convenience init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count >= 6, let n = UInt32(h.prefix(6), radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((n >> 16) & 255) / 255, green: CGFloat((n >> 8) & 255) / 255,
                  blue: CGFloat(n & 255) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex) ?? .white) }

    var hexString: String {
        let n = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02x%02x%02x",
                      Int((n.redComponent * 255).rounded()),
                      Int((n.greenComponent * 255).rounded()),
                      Int((n.blueComponent * 255).rounded()))
    }

    /// Формат Wallpaper Engine: "r g b" в диапазоне 0…1
    init(rgbString: String) {
        let p = rgbString.split(separator: " ").compactMap { Double($0) }
        self.init(.sRGB, red: p.count > 0 ? p[0] : 1, green: p.count > 1 ? p[1] : 1, blue: p.count > 2 ? p[2] : 1)
    }

    var rgbString: String {
        let n = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "%.4f %.4f %.4f", n.redComponent, n.greenComponent, n.blueComponent)
    }
}

extension Binding where Value == String {
    var hexColor: Binding<Color> {
        Binding<Color>(get: { Color(hex: self.wrappedValue) }, set: { self.wrappedValue = $0.hexString })
    }
}
