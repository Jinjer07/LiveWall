import SwiftUI
import AppKit

@main
struct LiveWallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppState.shared

    var body: some Scene {
        Window(tr("LiveWall — живые обои"), id: "main") {
            RootView()
                .environmentObject(app)
                .environmentObject(app.library)
                .environmentObject(app.engine)
                .environmentObject(app.steam)
                .frame(minWidth: 900, minHeight: 600)
                .background(Theme.bg)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 720)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(app)
                .environmentObject(app.library)
                .environmentObject(app.engine)
        } label: {
            MenuBarLabel().environmentObject(app.engine)
        }
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var engine: WallpaperEngine
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Image(systemName: engine.userPaused ? "pause.rectangle" : "photo.artframe")
            .onAppear {
                // Значок в строке меню живёт всё время — через него открываем главное окно,
                // даже если оно было закрыто (клик по иконке в Dock / Launchpad / Finder).
                MainWindow.opener = { openWindow(id: "main") }
            }
    }
}

/// Показ главного окна откуда угодно: Dock, Launchpad, Finder, меню-бар.
@MainActor
enum MainWindow {
    static var opener: (() -> Void)?

    static func isMain(_ w: NSWindow) -> Bool { !(w is DesktopWindow) && w.styleMask.contains(.titled) }

    static func show() {
        NSApp.setActivationPolicy(.regular)
        if let w = NSApp.windows.first(where: { isMain($0) && ($0.isVisible || $0.isMiniaturized) }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            opener?()
        }
        NSApp.activate(ignoringOtherApps: true)
        // Окно SwiftUI появляется асинхронно — выводим его вперёд ещё раз
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.windows.first(where: { isMain($0) && $0.isVisible })?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var engine: WallpaperEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let item = library.item(engine.primaryItemID) {
            Text(tr("Сейчас: %@", item.title))
        } else {
            Text(tr("Обои не выбраны"))
        }
        if case .available(let v) = app.updater.state {
            Button(tr("Обновить до %@", v)) { app.updater.installUpdate() }
            Divider()
        }
        Button(engine.userPaused ? tr("Продолжить") : tr("Пауза")) { engine.userPaused.toggle() }
        if app.activePlaylist?.mode == .timer {
            Button(tr("Следующие обои")) { app.nextInPlaylist() }
        }
        Menu(tr("Плейлист")) {
            Button(app.activePlaylistID == nil ? tr("✓ Без плейлиста") : tr("Без плейлиста")) { app.activatePlaylist(nil) }
            ForEach(app.playlists) { pl in
                Button((app.activePlaylistID == pl.id ? "✓ " : "") + pl.name) { app.activatePlaylist(pl.id) }
            }
        }
        let favs = library.items.filter(\.favorite)
        if !favs.isEmpty {
            Menu(tr("Избранное")) {
                ForEach(favs) { it in Button(it.title) { app.apply(it.id) } }
            }
        }
        Toggle(tr("Звук обоев"), isOn: Binding(get: { !app.settings.muted }, set: { app.settings.muted = !$0 }))
        Toggle(tr("Реакция на звук"), isOn: Binding(get: { app.settings.audioReactive }, set: { app.settings.audioReactive = $0 }))
        Toggle(tr("Снег"), isOn: Binding(get: { app.settings.snowEnabled }, set: { app.settings.snowEnabled = $0 }))
        Divider()
        Button(tr("Открыть LiveWall…")) { MainWindow.show() }
        Button(tr("Выйти")) { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let showWindowNote = Notification.Name("com.local.livewall.showMainWindow")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if RenderTest.requested { RenderTest.run(); return }
        // Только одна копия LiveWall: вторая (например, автозапуск после восстановления окон)
        // просит первую показать окно и сразу выходит, не трогая состояние и рабочий стол.
        let me = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != me && !$0.isTerminated }) {
            if !CommandLine.arguments.contains("--background") {
                DistributedNotificationCenter.default().postNotificationName(Self.showWindowNote, object: nil, userInfo: nil, deliverImmediately: true)
            }
            exit(0)
        }
        DistributedNotificationCenter.default().addObserver(forName: Self.showWindowNote, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MainWindow.show() }
        }

        AppState.shared.bootstrap()

        func isMainWindow(_ w: NSWindow) -> Bool {
            !(w is DesktopWindow) && w.styleMask.contains(.titled)
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let w = note.object as? NSWindow, isMainWindow(w) else { return }
                if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let w = note.object as? NSWindow, isMainWindow(w) else { return }
                DispatchQueue.main.async {
                    let anyVisible = NSApp.windows.contains { $0 !== w && isMainWindow($0) && $0.isVisible }
                    if !anyVisible { NSApp.setActivationPolicy(.accessory) }
                }
            }
        }
        if CommandLine.arguments.contains("--background") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                for w in NSApp.windows where isMainWindow(w) { w.close() }
                NSApp.setActivationPolicy(.accessory)
            }
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Клик по иконке в Dock / Launchpad / двойной клик в Finder, когда приложение уже запущено.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdown()
    }
}
