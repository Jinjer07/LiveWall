import Foundation
import AppKit

struct WEProjectInfo: Identifiable, Hashable {
    var id: String { folder.path }
    let workshopID: String
    let folder: URL
    let title: String
    let type: String
    let preview: URL?
    let supported: Bool
}

/// Разбор проектов Wallpaper Engine (project.json).
enum WEProject {
    static func readJSON(_ folder: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: folder.appendingPathComponent("project.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func info(folder: URL) -> WEProjectInfo? {
        guard let j = readJSON(folder) else { return nil }
        let type = (j["type"] as? String ?? "").lowercased()
        let file = j["file"] as? String
        let supported = (type == "video" || type == "web") && file != nil
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent(file!).path)
        return WEProjectInfo(workshopID: folder.lastPathComponent, folder: folder,
                             title: clean(j["title"] as? String ?? folder.lastPathComponent),
                             type: type.isEmpty ? "?" : type,
                             preview: (j["preview"] as? String).map { folder.appendingPathComponent($0) },
                             supported: supported)
    }

    static func makeItem(folder: URL) throws -> WallpaperItem {
        guard let j = readJSON(folder), let info = info(folder: folder) else { throw LWError("нет project.json") }
        guard info.supported else {
            throw LWError("тип «\(info.type)» не поддерживается (поддерживаются video и web; scene — закрытый формат)")
        }
        let t: WallpaperType = info.type == "video" ? .video : .web
        var props = t == .video ? DefaultProps.forType(.video) : []
        props += properties(j)
        let isWorkshop = folder.path.contains("/workshop/content/")
        return WallpaperItem(id: UUID().uuidString, title: info.title, type: t, folder: folder.path,
                             entry: j["file"] as? String ?? "",
                             preview: (j["preview"] as? String),
                             tags: (j["tags"] as? [String]) ?? [],
                             source: .steam,
                             workshopID: isWorkshop ? info.workshopID : nil,
                             properties: props)
    }

    static let knownLabels: [String: String] = [
        "ui_browse_properties_scheme_color": "Цвет схемы",
        "ui_browse_properties_alignment": "Выравнивание",
        "ui_browse_properties_volume": "Громкость",
        "ui_browse_properties_playback_rate": "Скорость",
    ]

    static func clean(_ s: String) -> String {
        var r = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let k = knownLabels[r] { return k }
        if r.hasPrefix("ui_") {
            r = r.replacingOccurrences(of: "ui_browse_properties_", with: "").replacingOccurrences(of: "ui_", with: "")
            r = r.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return r
    }

    private static func str(_ v: Any?) -> String {
        if let n = v as? NSNumber {
            let d = n.doubleValue
            return d == d.rounded() ? String(Int(d)) : String(d)
        }
        return v.map { "\($0)" } ?? ""
    }

    static func properties(_ j: [String: Any]) -> [WallpaperProperty] {
        guard let general = j["general"] as? [String: Any],
              let ps = general["properties"] as? [String: Any] else { return [] }
        var out: [WallpaperProperty] = []
        for (key, raw) in ps {
            guard let p = raw as? [String: Any], let type = p["type"] as? String else { continue }
            let label = clean(p["text"] as? String ?? key)
            let order = (p["order"] as? NSNumber)?.intValue ?? 100
            switch type.lowercased() {
            case "slider":
                let v = (p["value"] as? NSNumber)?.doubleValue ?? 0
                let lo = (p["min"] as? NSNumber)?.doubleValue ?? 0
                let hi = (p["max"] as? NSNumber)?.doubleValue ?? max(1, v)
                let step = (p["step"] as? NSNumber)?.doubleValue ?? ((p["precision"] as? NSNumber)?.intValue == 0 ? 1 : nil)
                out.append(WallpaperProperty(key: key, label: label, kind: .slider, value: .number(v), min: lo, max: hi, step: step, order: order))
            case "color":
                out.append(WallpaperProperty(key: key, label: label, kind: .color, value: .string(p["value"] as? String ?? "1 1 1"), order: order))
            case "bool":
                out.append(WallpaperProperty(key: key, label: label, kind: .bool, value: .bool((p["value"] as? NSNumber)?.boolValue ?? false), order: order))
            case "combo":
                let opts = (p["options"] as? [[String: Any]] ?? []).map {
                    PropertyOption(label: clean($0["label"] as? String ?? str($0["value"])), value: str($0["value"]))
                }
                out.append(WallpaperProperty(key: key, label: label, kind: .combo, value: .string(str(p["value"])), options: opts, order: order))
            case "textinput":
                out.append(WallpaperProperty(key: key, label: label, kind: .text, value: .string(p["value"] as? String ?? ""), order: order))
            default:
                continue
            }
        }
        return out.sorted { $0.order < $1.order }
    }
}

/// Импорт из папки мастерской Steam и загрузка через steamcmd.
@MainActor
final class SteamService: ObservableObject {
    static let appID = "431960" // Wallpaper Engine

    @Published var projects: [WEProjectInfo] = []
    @Published var log = ""
    @Published var busy = false
    @Published var status = ""

    weak var app: AppState?

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    func steamcmdPath() -> String? {
        let fm = FileManager.default
        if let c = app?.settings.steamcmdPath, !c.isEmpty {
            let p = (c as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: p) { return p }
        }
        let cands = ["/opt/homebrew/bin/steamcmd", "/usr/local/bin/steamcmd",
                     home.appendingPathComponent("Steam/steamcmd.sh").path,
                     home.appendingPathComponent("steamcmd/steamcmd.sh").path,
                     home.appendingPathComponent("Library/Application Support/Steam/steamcmd.sh").path]
        return cands.first { fm.isExecutableFile(atPath: $0) }
    }

    var candidateDirs: [URL] {
        let sub = "steamapps/workshop/content/\(Self.appID)"
        var list: [URL] = []
        if let c = app?.settings.steamWorkshopPath, !c.isEmpty { list.append(URL(fileURLWithPath: (c as NSString).expandingTildeInPath)) }
        list += [home.appendingPathComponent("Library/Application Support/Steam/\(sub)"),
                 home.appendingPathComponent("Steam/\(sub)"),
                 home.appendingPathComponent("steamcmd/\(sub)")]
        if let cmd = steamcmdPath() {
            let resolved = URL(fileURLWithPath: cmd).resolvingSymlinksInPath().deletingLastPathComponent()
            list.append(resolved.appendingPathComponent(sub))
        }
        var seen = Set<String>()
        return list.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    var existingDirs: [URL] { candidateDirs.filter { FileManager.default.isDirectory($0) } }

    func scan() {
        var out: [WEProjectInfo] = []
        for dir in existingDirs {
            let subs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for s in subs where FileManager.default.isDirectory(s) {
                if let i = WEProject.info(folder: s) { out.append(i) }
            }
        }
        projects = out.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        status = existingDirs.isEmpty
            ? "Папка мастерской Wallpaper Engine не найдена. Укажите её вручную или скачайте предмет через steamcmd."
            : "Найдено проектов: \(out.count), поддерживается: \(out.filter(\.supported).count)"
    }

    func isImported(_ p: WEProjectInfo) -> Bool {
        app?.library.items.contains { $0.folderURL.standardizedFileURL.path == p.folder.standardizedFileURL.path } ?? false
    }

    @discardableResult
    func importProject(_ p: WEProjectInfo) -> WallpaperItem? {
        guard let lib = app?.library, !isImported(p) else { return nil }
        do {
            let item = try WEProject.makeItem(folder: p.folder)
            lib.add(item)
            lib.generatePreview(for: item)
            objectWillChange.send()
            return item
        } catch {
            status = "\(p.title): \(error.localizedDescription)"
            return nil
        }
    }

    func importAllSupported() {
        var n = 0
        for p in projects where p.supported && !isImported(p) { if importProject(p) != nil { n += 1 } }
        status = "Импортировано: \(n)"
    }

    static func parseID(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #"id=(\d+)"#, options: .regularExpression) {
            return String(t[r].dropFirst(3))
        }
        if let r = t.range(of: #"\d{6,}"#, options: .regularExpression) { return String(t[r]) }
        return nil
    }

    func download(_ input: String) {
        guard !busy else { return }
        guard let id = Self.parseID(input) else { status = "Не удалось распознать ID предмета"; return }
        guard let cmd = steamcmdPath() else { status = "steamcmd не найден. Установите его (см. инструкцию ниже) или укажите путь."; return }
        let user = app?.settings.steamUser.trimmingCharacters(in: .whitespaces) ?? ""
        guard !user.isEmpty else { status = "Укажите логин Steam"; return }

        busy = true
        status = "Загрузка предмета \(id)…"
        log += "\n> steamcmd +login \(user) +workshop_download_item \(Self.appID) \(id) +quit\n"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd)
        p.arguments = ["+login", user, "+workshop_download_item", Self.appID, id, "+quit"]
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.appendLog(s) }
        }
        p.terminationHandler = { proc in
            reader.readabilityHandler = nil
            let rest = reader.readDataToEndOfFile()
            let s = String(data: rest, encoding: .utf8) ?? ""
            let code = proc.terminationStatus
            Task { @MainActor [weak self] in
                self?.appendLog(s)
                self?.finishDownload(id: id, code: code)
            }
        }
        do { try p.run() } catch {
            busy = false
            status = "Не удалось запустить steamcmd: \(error.localizedDescription)"
        }
    }

    private func appendLog(_ s: String) {
        log += s
        if log.count > 40000 { log = String(log.suffix(30000)) }
    }

    private func finishDownload(id: String, code: Int32) {
        busy = false
        var folder: URL?
        if let r = log.range(of: "Downloaded item \(id) to \"([^\"]+)\"", options: [.regularExpression, .backwards]) {
            let m = String(log[r])
            if let q1 = m.firstIndex(of: "\""), let q2 = m.lastIndex(of: "\""), q1 < q2 {
                folder = URL(fileURLWithPath: String(m[m.index(after: q1)..<q2]))
            }
        }
        if folder == nil {
            folder = candidateDirs.map { $0.appendingPathComponent(id) }.first { FileManager.default.isDirectory($0) }
        }
        guard let folder, let info = WEProject.info(folder: folder) else {
            status = "Не удалось скачать (код \(code)). Если steamcmd просит пароль — нажмите «Войти в steamcmd» и войдите один раз в Терминале."
            return
        }
        scan()
        if !info.supported {
            status = "Скачано «\(info.title)», но тип «\(info.type)» не поддерживается."
        } else if importProject(info) != nil {
            status = "Скачано и добавлено в библиотеку: «\(info.title)»"
        } else if isImported(info) {
            status = "«\(info.title)» уже в библиотеке"
        }
    }

    /// Открывает Терминал, где пользователь сам вводит пароль и код Steam Guard (данные кешируются steamcmd).
    func openLoginTerminal() {
        guard let cmd = steamcmdPath() else { status = "steamcmd не найден"; return }
        let user = app?.settings.steamUser ?? ""
        let script = """
        #!/bin/bash
        echo "Вход в Steam для LiveWall. Введите пароль и код Steam Guard — steamcmd запомнит вход."
        '\(cmd)' +login '\(user.replacingOccurrences(of: "'", with: ""))' +quit
        echo
        echo "Готово. Это окно можно закрыть."
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("livewall-steam-login.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            status = "Не удалось открыть Терминал: \(error.localizedDescription)"
        }
    }
}
