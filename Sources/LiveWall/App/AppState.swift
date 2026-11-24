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
    @Published var audioStatus = "Выключено"
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
        if firstRun, engine.assignments.isEmpty, let s = library.items.first(where: { $0.type == .scene }) {
            engine.apply(s.id, screen: nil)
        }
        playlistTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.playlistTick() }
        }
        if activePlaylistID != nil { playlistTick() }
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
        if old.audioReactive != settings.audioReactive { updateAudioCapture() }
        if old.launchAtLogin != settings.launchAtLogin { LoginItem.set(settings.launchAtLogin) }
        if old.spanMode != settings.spanMode { engine.refresh(force: true) }
    }

    func updateAudioCapture() {
        guard settings.audioReactive else {
            audio.stop()
            audioStatus = "Выключено"
            engine.pushAudio([Float](repeating: 0, count: 128))
            return
        }
        audioStatus = "Запуск…"
        Task {
            do {
                try await audio.start { [weak self] spectrum in
                    MainActor.assumeIsolated {
                        self?.audioSubject.send(spectrum)
                        self?.engine.pushAudio(spectrum)
                    }
                }
                audioStatus = "Работает"
            } catch {
                audioStatus = "Нет доступа: \(error.localizedDescription). Разрешите LiveWall в «Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука», затем перезапустите приложение."
            }
        }
    }

    // MARK: Обои

    func apply(_ id: String?, screen: String? = nil) {
        activePlaylistID = nil
        engine.apply(id, screen: screen)
    }

    func remove(_ item: WallpaperItem) {
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
