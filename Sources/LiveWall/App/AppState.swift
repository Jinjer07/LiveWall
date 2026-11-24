import Foundation
import AppKit
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let library: LibraryStore
    let engine: WallpaperEngine
    let steam: SteamService
    let monitor = PerformanceMonitor()
    let mouse = MouseTracker()
    let audio = AudioCapture()
    let audioSubject = PassthroughSubject<[Float], Never>()
    let sysInfo = SystemInfoService()
    let ambientService = AmbientService()
    let gallery = GalleryService()
    let updater = UpdateService()
    let steamAccount = SteamAccount()
    var ambient: AmbientState { ambientService.state }

    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            Persistence.save(settings, to: Paths.settings)
            settingsChanged(old: oldValue)
        }
    }
    @Published var playlists: [Playlist] = [] { didSet { saveState() } }
    @Published var activePlaylistID: String? {
        didSet { if oldValue != activePlaylistID { lastSwitch = Date(); saveState() } }
    }
    @Published var audioStatus = tr("Выключено")
    @Published var sidebar: SidebarItem? = .library
    @Published var toast: String?
    @Published var overlay: AppOverlay?

    lazy var sceneEditor = SceneEditorModel()

    private var playlistIndex = 0
    private var lastSwitch = Date()
    private var playlistTimer: Timer?
    private var bootstrapped = false

    private init() {
        Paths.ensure()
        settings = Persistence.loadMerged(AppSettings(), from: Paths.settings)
        let st = Persistence.loadMerged(PersistedState(), from: Paths.state)
        library = LibraryStore()
        engine = WallpaperEngine()
        steam = SteamService()
        // Сначала назначения, затем свойства с didSet (они сохраняют состояние на диск).
        engine.assignments = st.assignments
        engine.spanItemID = st.spanItemID
        engine.app = self
        sysInfo.app = self
        ambientService.app = self
        gallery.app = self
        updater.app = self
        steamAccount.app = self
        Loc.lang = Loc.resolve(settings.language)
        playlistIndex = st.playlistIndex
        playlists = st.playlists
        activePlaylistID = st.activePlaylistID
        steam.app = self
    }

    // MARK: Запуск

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        RuntimeFiles.install()
        library.cleanupOrphans()
        library.fixAnimatedPreviews()
        var firstRun = false
        if !settings.samplesInstalled {
            Samples.install(into: library)
            settings.samplesInstalled = true
            firstRun = true
        }
        monitor.screensProvider = { [weak self] in self?.engine.screens ?? [] }
        monitor.onChange = { [weak self] in self?.engine.updatePauseStates() }
        engine.setup()
        monitor.start()
        mouse.handler = { [weak self] kind, p in self?.engine.handleMouse(kind, at: p) }
        applyRuntimeSettings()
        updateAudioCapture()
        ambientService.start()
        updater.start()
        if firstRun, engine.assignments.isEmpty, let s = library.items.first(where: { $0.type == .scene }) {
            engine.apply(s.id, screen: nil)
        }
        playlistTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.playlistTick() }
        }
        if activePlaylistID != nil { playlistTick() }
        if CommandLine.arguments.contains("--import-workshop") { steam.importAllAsPlaylist() }
    }

    func shutdown() {
        library.save()
        saveState()
        audio.stop()
        engine.shutdown()
    }

    func saveState() {
        let st = PersistedState(assignments: engine.assignments, spanItemID: engine.spanItemID,
                                activePlaylistID: activePlaylistID, playlists: playlists, playlistIndex: playlistIndex)
        Persistence.save(st, to: Paths.state)
    }

    // MARK: Настройки

    private func applyRuntimeSettings() {
        engine.applySettings()
        mouse.clicksEnabled = settings.clickInteraction
        if settings.mouseInteraction || settings.clickInteraction { mouse.start() } else { mouse.stop() }
    }

    private func settingsChanged(old: AppSettings) {
        applyRuntimeSettings()
        if old.audioReactive != settings.audioReactive { updateAudioCapture(userInitiated: true) }
        if old.launchAtLogin != settings.launchAtLogin { LoginItem.set(settings.launchAtLogin) }
        if old.spanMode != settings.spanMode { engine.refresh(force: true) }
        if old.language != settings.language {
            Loc.lang = Loc.resolve(settings.language)
            engine.refresh(force: true)   // перезапуск рантаймов с новым языком
            sysInfo.refresh()
            ambientService.recompute()
        }
        if old.ambientEnabled != settings.ambientEnabled { engine.pushAmbient(ambientService.state) }
        if old.nowPlayingWidgets != settings.nowPlayingWidgets || old.calendarWidgets != settings.calendarWidgets { sysInfo.refresh() }
    }

    @Published var audioNeedsPermission = false

    /// userInitiated — вызвано кнопкой: тогда можно показать системный запрос macOS.
    /// При обычном запуске без разрешения запрос не показываем, чтобы не надоедать.
    func updateAudioCapture(userInitiated: Bool = false) {
        guard settings.audioReactive else {
            audio.stop()
            audioStatus = tr("Выключено")
            audioNeedsPermission = false
            engine.pushAudio([Float](repeating: 0, count: 128))
            return
        }
        if !AudioCapture.tapSupported && !CGPreflightScreenCaptureAccess() {
            if userInitiated {
                // Показывает системный запрос (или открывает список в Настройках)
                if !CGRequestScreenCaptureAccess() {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            audioNeedsPermission = true
            audioStatus = tr("Нет разрешения «Запись экрана и системного звука». Нажмите «Выдать доступ», включите LiveWall в списке и перезапустите приложение.")
            return
        }
        audioNeedsPermission = false
        audioStatus = tr("Запуск…")
        Task {
            do {
                try await audio.start { [weak self] spectrum in
                    MainActor.assumeIsolated {
                        self?.audioSubject.send(spectrum)
                        self?.engine.pushAudio(spectrum)
                    }
                }
                audioStatus = audio.usingTap ? tr("Работает (системный звук)") : tr("Работает")
            } catch {
                audioStatus = tr("Нет доступа: %@. Разрешите LiveWall в «Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука», затем перезапустите приложение.", error.localizedDescription)
            }
        }
    }

    // MARK: Обои

    func apply(_ id: String?, screen: String? = nil) {
        activePlaylistID = nil
        engine.apply(id, screen: screen)
    }

    func remove(_ item: WallpaperItem) {
        // Удалённые обои из мастерской не возвращаем при синхронизации
        if item.source == .steam, let wid = item.workshopID, !settings.hiddenWorkshopIDs.contains(wid) {
            settings.hiddenWorkshopIDs.append(wid)
        }
        engine.itemRemoved(item.id)
        for i in playlists.indices {
            playlists[i].items.removeAll { $0 == item.id }
            for j in playlists[i].slots.indices where playlists[i].slots[j].wallpaperID == item.id {
                playlists[i].slots[j].wallpaperID = nil
            }
        }
        library.remove(item)
    }

    func openEditor(_ item: WallpaperItem?) {
        if let item { sceneEditor.open(item) } else { sceneEditor.newScene() }
        sidebar = .editor
    }

    func showToast(_ s: String) {
        toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { if self?.toast == s { self?.toast = nil } }
        }
    }

    // MARK: Плейлисты

    var activePlaylist: Playlist? { playlists.first { $0.id == activePlaylistID } }

    func activatePlaylist(_ id: String?) {
        activePlaylistID = id
        playlistIndex = 0
        guard let pl = activePlaylist else { return }
        switch pl.mode {
        case .timer:
            let valid = pl.items.filter { library.item($0) != nil }
            guard !valid.isEmpty else { return }
            playlistIndex = pl.shuffle ? Int.random(in: 0..<valid.count) : 0
            engine.apply(valid[playlistIndex], screen: nil)
        case .timeOfDay:
            if let w = pl.slotWallpaper(at: Date()) { engine.apply(w, screen: nil) }
        }
        lastSwitch = Date()
        saveState()
    }

    func nextInPlaylist() {
        guard let pl = activePlaylist, pl.mode == .timer else { return }
        let valid = pl.items.filter { library.item($0) != nil }
        guard !valid.isEmpty else { return }
        if pl.shuffle && valid.count > 1 {
            var n = playlistIndex
            while n == playlistIndex { n = Int.random(in: 0..<valid.count) }
            playlistIndex = n
        } else {
            playlistIndex = (playlistIndex + 1) % valid.count
        }
        engine.apply(valid[playlistIndex], screen: nil)
        lastSwitch = Date()
        saveState()
    }

    private func playlistTick() {
        guard let pl = activePlaylist else { return }
        switch pl.mode {
        case .timer:
            if Date().timeIntervalSince(lastSwitch) >= max(1, pl.intervalMinutes) * 60 { nextInPlaylist() }
        case .timeOfDay:
            if let w = pl.slotWallpaper(at: Date()), engine.primaryItemID != w { engine.apply(w, screen: nil) }
        }
    }
}

/// Перезапуск приложения (нужен после выдачи разрешений macOS).
@MainActor
enum AppRestart {
    static func now() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        AppState.shared.shutdown()
        NSApp.terminate(nil)
    }
}
