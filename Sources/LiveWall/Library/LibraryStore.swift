import Foundation
import AppKit
import AVFoundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [WallpaperItem] = []
    @Published var thumbVersion = 0

    private var saveWork: DispatchWorkItem?

    init() {
        items = Persistence.load([WallpaperItem].self, from: Paths.index) ?? []
    }

    // MARK: Базовые операции

    func save() {
        saveWork?.cancel(); saveWork = nil
        Persistence.save(items, to: Paths.index)
    }

    func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save() } }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func item(_ id: String?) -> WallpaperItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    func add(_ item: WallpaperItem) {
        items.append(item)
        save()
    }

    func update(_ item: WallpaperItem, immediate: Bool = true) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item
        immediate ? save() : scheduleSave()
    }

    func remove(_ item: WallpaperItem) {
        items.removeAll { $0.id == item.id }
        save()
        if isManaged(item) {
            try? FileManager.default.trashItem(at: item.folderURL, resultingItemURL: nil)
        }
        let ext = Paths.previews.appendingPathComponent("\(item.id).jpg")
        try? FileManager.default.removeItem(at: ext)
    }

    func isManaged(_ item: WallpaperItem) -> Bool {
        item.folderURL.standardizedFileURL.path.hasPrefix(Paths.library.standardizedFileURL.path + "/")
    }

    func newFolder() -> URL {
        let url = Paths.library.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Удаляет папки в библиотеке, на которые никто не ссылается (например, несохранённые сцены).
    func cleanupOrphans() {
        let used = Set(items.map { $0.folderURL.standardizedFileURL.lastPathComponent })
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Paths.library, includingPropertiesForKeys: nil)) ?? []
        for d in dirs where FileManager.default.isDirectory(d) && !used.contains(d.lastPathComponent) {
            try? FileManager.default.removeItem(at: d)
        }
    }

    var allTags: [String] {
        Array(Set(items.flatMap { $0.tags })).sorted()
    }

    // MARK: Импорт

    @discardableResult
    func importURLs(_ urls: [URL]) -> (imported: [WallpaperItem], errors: [String]) {
        var ok: [WallpaperItem] = []
        var errs: [String] = []
        for u in urls {
            do {
                let item = try importOne(u)
                add(item)
                ok.append(item)
                generatePreview(for: item)
            } catch {
                errs.append("\(u.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (ok, errs)
    }

    private func importOne(_ url: URL) throws -> WallpaperItem {
        let fm = FileManager.default
        let title = url.deletingPathExtension().lastPathComponent
        if fm.isDirectory(url) {
            if fm.fileExists(atPath: url.appendingPathComponent("project.json").path) {
                return try WEProject.makeItem(folder: url)
            }
            if fm.fileExists(atPath: url.appendingPathComponent("scene.json").path) {
                let dest = newFolder()
                try copyContents(of: url, to: dest)
                return WallpaperItem(id: UUID().uuidString, title: title, type: .scene, folder: dest.path,
                                     entry: "scene.json", properties: DefaultProps.forType(.scene))
            }
            if fm.fileExists(atPath: url.appendingPathComponent("index.html").path) {
                let dest = newFolder()
                try copyContents(of: url, to: dest)
                return WallpaperItem(id: UUID().uuidString, title: title, type: .web, folder: dest.path, entry: "index.html")
            }
            if !FileKinds.images(in: url).isEmpty {
                // Слайдшоу ссылается на исходную папку — можно докладывать туда картинки.
                return WallpaperItem(id: UUID().uuidString, title: title, type: .slideshow, folder: url.path,
                                     entry: "", properties: DefaultProps.forType(.slideshow))
            }
            throw LWError(tr("в папке нет видео/картинок, index.html, scene.json или project.json"))
        }

        let ext = url.pathExtension.lowercased()
        if ext == "wallpkg" { return try unpackPackage(url) }
        if ext == "html" || ext == "htm" {
            return WallpaperItem(id: UUID().uuidString, title: title, type: .web,
                                 folder: url.deletingLastPathComponent().path, entry: url.lastPathComponent)
        }
        let type: WallpaperType
        if FileKinds.video.contains(ext) { type = .video }
        else if FileKinds.image.contains(ext) { type = .image }
        else if FileKinds.shader.contains(ext) { type = .shader }
        else { throw LWError(tr("неподдерживаемый формат .%@", ext)) }

        let dest = newFolder()
        let name = url.lastPathComponent
        try fm.copyItem(at: url, to: dest.appendingPathComponent(name))
        var props = DefaultProps.forType(type)
        if type == .shader, let src = try? String(contentsOf: url, encoding: .utf8) {
            props += ShaderParser.properties(from: src)
        }
        return WallpaperItem(id: UUID().uuidString, title: title, type: type, folder: dest.path, entry: name, properties: props)
    }

    private func copyContents(of src: URL, to dest: URL) throws {
        let fm = FileManager.default
        for f in try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) {
            try fm.copyItem(at: f, to: dest.appendingPathComponent(f.lastPathComponent))
        }
    }

    // MARK: Создание

    func createShader() -> WallpaperItem {
        let dest = newFolder()
        let src = Samples.shaderTemplate
        try? src.write(to: dest.appendingPathComponent("shader.frag"), atomically: true, encoding: .utf8)
        let item = WallpaperItem(id: UUID().uuidString, title: tr("Новый шейдер"), type: .shader, folder: dest.path,
                                 entry: "shader.frag",
                                 properties: DefaultProps.forType(.shader) + ShaderParser.properties(from: src))
        add(item)
        return item
    }

    // MARK: Пакеты .wallpkg

    func exportPackage(_ item: WallpaperItem, to dest: URL) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let content = tmp.appendingPathComponent("content", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try fm.copyItem(at: item.folderURL, to: content)
        var m = item
        m.folder = ""
        if let p = item.previewURL, item.preview?.hasPrefix("/") == true, fm.fileExists(atPath: p.path) {
            try? fm.removeItem(at: content.appendingPathComponent("preview.jpg"))
            try fm.copyItem(at: p, to: content.appendingPathComponent("preview.jpg"))
            m.preview = "preview.jpg"
        }
        try JSONEncoder.lw.encode(m).write(to: content.appendingPathComponent("manifest.json"))
        try? fm.removeItem(at: dest)
        try Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", content.path, dest.path])
    }

    private func unpackPackage(_ url: URL) throws -> WallpaperItem {
        let dest = newFolder()
        do {
            try Shell.run("/usr/bin/ditto", ["-x", "-k", url.path, dest.path])
            guard var m = Persistence.load(WallpaperItem.self, from: dest.appendingPathComponent("manifest.json")) else {
                throw LWError(tr("в пакете нет manifest.json"))
            }
            m.id = UUID().uuidString
            m.folder = dest.path
            m.source = .local
            m.added = Date()
            return m
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
    }

    // MARK: Превью

    func needsPreview(_ item: WallpaperItem) -> Bool {
        guard let u = item.previewURL else { return true }
        return !FileManager.default.fileExists(atPath: u.path)
    }

    func generatePreview(for item: WallpaperItem) {
        guard needsPreview(item) else { return }
        switch item.type {
        case .video where FileKinds.avPlayable.contains(item.entryURL.pathExtension.lowercased()):
            let id = item.id, url = item.entryURL
            Task {
                let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 640, height: 640)
                if let r = try? await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)) {
                    self.savePreview(NSImage(cgImage: r.image, size: .zero), for: id)
                }
            }
        case .image:
            if let img = NSImage(contentsOf: item.entryURL) { savePreview(img, for: item.id) }
        case .slideshow:
            if let f = FileKinds.images(in: item.folderURL).first, let img = NSImage(contentsOf: f) { savePreview(img, for: item.id) }
        default:
            break // веб/шейдер/сцена — снимок делает рендерер после запуска
        }
    }

    /// Средний кадр анимированного превью (первый кадр у GIF из мастерской часто чёрный).
    static func stillFrame(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0, let cg = CGImageSourceCreateImageAtIndex(src, count / 2, nil) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    /// Разовая миграция: GIF-обложки → JPEG из среднего кадра.
    func fixAnimatedPreviews() {
        for item in items {
            guard let url = item.previewURL, url.pathExtension.lowercased() == "gif",
                  FileManager.default.fileExists(atPath: url.path),
                  let img = Self.stillFrame(url) else { continue }
            savePreview(img, for: item.id)
        }
    }

    func savePreview(_ image: NSImage, for id: String) {
        guard var item = item(id), let jpeg = image.jpegData(maxDimension: 640) else { return }
        let url: URL
        let stored: String
        if isManaged(item) {
            url = item.folderURL.appendingPathComponent("preview.jpg"); stored = "preview.jpg"
        } else {
            url = Paths.previews.appendingPathComponent("\(id).jpg"); stored = url.path
        }
        do { try jpeg.write(to: url, options: .atomic) } catch { return }
        item.preview = stored
        update(item)
        thumbVersion += 1
    }
}

// MARK: - Разбор свойств из шейдера
// Формат: uniform float u_speed; // Скорость [0, 5] = 1
//         uniform vec3 u_color;  // Цвет = 1 0.5 0
//         uniform bool u_flag;   // Включить = true

enum ShaderParser {
    static func properties(from src: String) -> [WallpaperProperty] {
        var out: [WallpaperProperty] = []
        let re = try! NSRegularExpression(pattern: #"^\s*uniform\s+(float|vec3|bool|int)\s+(u_\w+)\s*;\s*//\s*(.*)$"#,
                                          options: [.anchorsMatchLines])
        let ns = src as NSString
        for (i, m) in re.matches(in: src, range: NSRange(location: 0, length: ns.length)).enumerated() {
            let type = ns.substring(with: m.range(at: 1))
            let key = ns.substring(with: m.range(at: 2))
            let comment = ns.substring(with: m.range(at: 3))
            var label = comment
            if let cut = comment.firstIndex(where: { $0 == "[" || $0 == "=" }) { label = String(comment[..<cut]) }
            label = label.trimmingCharacters(in: .whitespaces)
            if label.isEmpty { label = key }
            let def = comment.split(separator: "=", maxSplits: 1).dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) }
            var lo = 0.0, hi = 1.0
            if let r = comment.range(of: #"\[([^\]]+)\]"#, options: .regularExpression) {
                let nums = comment[r].dropFirst().dropLast().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if nums.count == 2 { lo = nums[0]; hi = nums[1] }
            }
            switch type {
            case "vec3":
                out.append(WallpaperProperty(key: key, label: label, kind: .color, value: .string(def ?? "1 1 1"), order: i))
            case "bool":
                out.append(WallpaperProperty(key: key, label: label, kind: .bool, value: .bool(def == "true" || def == "1"), order: i))
            default:
                let v = def.flatMap { Double($0) } ?? lo
                out.append(WallpaperProperty(key: key, label: label, kind: .slider, value: .number(v), min: lo, max: hi,
                                             step: type == "int" ? 1 : nil, order: i))
            }
        }
        return out
    }
}
