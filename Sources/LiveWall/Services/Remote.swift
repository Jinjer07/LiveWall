import Foundation
import AppKit
import CryptoKit

enum RemoteConfig {
    static let repo = "Jinjer07/LiveWall"
    static let galleryBase = URL(string: "https://raw.githubusercontent.com/\(repo)/main/gallery/")!
    static let latestRelease = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }
}

// MARK: - Галерея: готовые сцены и шейдеры из репозитория

struct GalleryItem: Codable, Identifiable, Hashable {
    struct Text: Codable, Hashable { var ru: String; var en: String }
    var id: String
    var type: String          // scene | shader
    var title: Text
    var description: Text
    var tags: [String]
    var file: String
    var preview: String
    var version: Int

    var localizedTitle: String { Loc.isEnglish ? title.en : title.ru }
    var localizedDescription: String { Loc.isEnglish ? description.en : description.ru }
    var wallpaperType: WallpaperType { type == "shader" ? .shader : .scene }
}

private struct GalleryIndex: Codable { var version: Int; var items: [GalleryItem] }

@MainActor
final class GalleryService: ObservableObject {
    @Published private(set) var items: [GalleryItem] = []
    @Published private(set) var loading = false
    @Published var error: String?
    @Published private(set) var installing: Set<String> = []
    @Published private(set) var previews: [String: NSImage] = [:]

    weak var app: AppState?
    private var lastLoad = Date.distantPast
    private let cacheDir = Paths.root.appendingPathComponent("GalleryCache", isDirectory: true)

    func loadIfNeeded() {
        guard !loading, items.isEmpty || Date().timeIntervalSince(lastLoad) > 3600 else { return }
        load()
    }

    func load() {
        loading = true
        error = nil
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let url = RemoteConfig.galleryBase.appendingPathComponent("index.json")
        Task {
            defer { loading = false }
            do {
                var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                req.setValue("LiveWall", forHTTPHeaderField: "User-Agent")
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw LWError(tr("Каталог недоступен")) }
                let idx = try JSONDecoder().decode(GalleryIndex.self, from: data)
                items = idx.items
                lastLoad = Date()
                for it in idx.items { loadPreview(it) }
            } catch {
                self.error = tr("Не удалось загрузить галерею: %@", error.localizedDescription)
            }
        }
    }

    private func loadPreview(_ it: GalleryItem) {
        guard previews[it.id] == nil else { return }
        let cached = cacheDir.appendingPathComponent("\(it.id)-v\(it.version).jpg")
        if let img = NSImage(contentsOf: cached) { previews[it.id] = img; return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: RemoteConfig.galleryBase.appendingPathComponent(it.preview)),
                  let img = NSImage(data: data) else { return }
            try? data.write(to: cached)
            previews[it.id] = img
        }
    }

    func installed(_ it: GalleryItem) -> WallpaperItem? {
        app?.library.items.first { $0.galleryID == it.id }
    }

    /// Скачивает элемент галереи в библиотеку. apply — сразу поставить на рабочий стол.
    func install(_ it: GalleryItem, apply: Bool) {
        guard let app, !installing.contains(it.id) else { return }
        if let existing = installed(it) {
            if apply { app.apply(existing.id); app.showToast(tr("Применено: %@", existing.title)) }
            return
        }
        installing.insert(it.id)
        Task {
            defer { installing.remove(it.id) }
            do {
                let (data, resp) = try await URLSession.shared.data(from: RemoteConfig.galleryBase.appendingPathComponent(it.file))
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw LWError(tr("Файл недоступен")) }
                let lib = app.library
                let folder = lib.newFolder()
                let entry = it.wallpaperType == .scene ? "scene.json" : "shader.frag"
                try data.write(to: folder.appendingPathComponent(entry))
                var props = DefaultProps.forType(it.wallpaperType)
                if it.wallpaperType == .shader, let src = String(data: data, encoding: .utf8) {
                    props += ShaderParser.properties(from: src)
                }
                var item = WallpaperItem(id: UUID().uuidString, title: it.localizedTitle, type: it.wallpaperType,
                                         folder: folder.path, entry: entry, tags: it.tags, properties: props)
                item.galleryID = it.id
                if let img = previews[it.id], let jpeg = img.jpegData(maxDimension: 640) {
                    try? jpeg.write(to: folder.appendingPathComponent("preview.jpg"))
                    item.preview = "preview.jpg"
                }
                lib.add(item)
                objectWillChange.send()
                if apply { app.apply(item.id) }
                app.showToast(apply ? tr("Установлено и применено: %@", item.title) : tr("Добавлено в библиотеку: %@", item.title))
            } catch {
                app.showToast(tr("Ошибка установки: %@", error.localizedDescription))
            }
        }
    }
}

// MARK: - Обновления через GitHub Releases

@MainActor
final class UpdateService: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate, available(version: String), downloading(Double), installing, failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var notes: String = ""
    @Published private(set) var latestVersion: String?
    @Published var lastChecked: Date?

    weak var app: AppState?
    private var timer: Timer?
    private var assetURL: URL?
    private var expectedSHA: String?

    var updateAvailable: Bool { if case .available = state { return true }; return false }

    func start() {
        guard timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            MainActor.assumeIsolated { if self?.app?.settings.autoCheckUpdates ?? true { self?.check(silent: true) } }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.app?.settings.autoCheckUpdates ?? true { self?.check(silent: true) } }
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    func check(silent: Bool = false) {
        if case .downloading = state { return }
        if state == .installing { return }
        state = .checking
        Task {
            do {
                var req = URLRequest(url: RemoteConfig.latestRelease, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                req.setValue("LiveWall/\(RemoteConfig.appVersion)", forHTTPHeaderField: "User-Agent")
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = j["tag_name"] as? String else { throw LWError(tr("GitHub не ответил")) }
                lastChecked = Date()
                let body = j["body"] as? String ?? ""
                let assets = j["assets"] as? [[String: Any]] ?? []
                let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
                assetURL = (zip?["browser_download_url"] as? String).flatMap(URL.init(string:))
                expectedSHA = Self.sha(in: body)
                notes = body
                latestVersion = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if Self.isNewer(tag, than: RemoteConfig.appVersion), assetURL != nil {
                    state = .available(version: latestVersion ?? tag)
                    if silent { app?.showToast(tr("Доступно обновление LiveWall %@", latestVersion ?? tag)) }
                } else {
                    state = .upToDate
                }
            } catch {
                state = silent ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    /// Ищет в описании релиза строку вида «SHA-256: <hex>».
    static func sha(in body: String) -> String? {
        guard let r = body.range(of: #"(?i)sha-?256[^0-9a-f]*([0-9a-f]{64})"#, options: .regularExpression) else { return nil }
        let m = String(body[r])
        guard let h = m.range(of: #"[0-9a-f]{64}"#, options: .regularExpression) else { return nil }
        return String(m[h]).lowercased()
    }

    func installUpdate() {
        guard let url = assetURL, case .available = state else { return }
        state = .downloading(0)
        let delegate = DownloadProgress { [weak self] p in
            Task { @MainActor in if case .downloading = self?.state { self?.state = .downloading(p) } }
        }
        Task {
            do {
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                let (tmp, resp) = try await session.download(from: url)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw LWError(tr("Не удалось скачать обновление")) }
                state = .installing
                try await self.install(zip: tmp)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func install(zip: URL) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("livewall-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let archive = work.appendingPathComponent("update.zip")
        try fm.moveItem(at: zip, to: archive)

        // Проверка контрольной суммы, если она указана в описании релиза
        if let expected = expectedSHA {
            let data = try Data(contentsOf: archive)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw LWError(tr("Контрольная сумма не совпала — обновление отменено")) }
        }

        let unpack = work.appendingPathComponent("unpacked", isDirectory: true)
        try Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpack.path])
        guard let newApp = try fm.contentsOfDirectory(at: unpack, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }),
              let newBundle = Bundle(url: newApp),
              newBundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw LWError(tr("В архиве нет подходящего LiveWall.app"))
        }

        let current = Bundle.main.bundleURL
        guard current.pathExtension == "app" else { throw LWError(tr("Обновление работает только для собранного LiveWall.app")) }
        guard fm.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            throw LWError(tr("Нет прав на запись в %@", current.deletingLastPathComponent().path))
        }

        // Скрипт ждёт выхода приложения, подменяет бандл и запускает новую версию.
        let script = work.appendingPathComponent("install.sh")
        let pid = ProcessInfo.processInfo.processIdentifier
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let sh = """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        rm -rf \(q(current.path + ".old"))
        mv \(q(current.path)) \(q(current.path + ".old")) && mv \(q(newApp.path)) \(q(current.path)) || { mv \(q(current.path + ".old")) \(q(current.path)); exit 1; }
        xattr -dr com.apple.quarantine \(q(current.path)) 2>/dev/null
        rm -rf \(q(current.path + ".old")) \(q(work.path))
        open \(q(current.path))
        """
        try sh.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        try p.run()
        app?.shutdown()
        NSApp.terminate(nil)
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    init(_ f: @escaping (Double) -> Void) { onProgress = f }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
