import AppKit
import Combine

/// Окно, живущее на уровне рабочего стола: под иконками, над системной картинкой.
final class DesktopWindow: NSWindow {
    let container = NSView()

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        contentView = container
        setFrame(frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WallpaperEngine: ObservableObject {
    struct ScreenInfo: Identifiable, Hashable {
        let key: String
        let name: String
        let frame: CGRect       // координаты Cocoa
        let cgBounds: CGRect    // координаты CoreGraphics (начало сверху слева)
        let displayID: CGDirectDisplayID
        var id: String { key }
    }

    final class Slot {
        let info: ScreenInfo
        let window: DesktopWindow
        var renderer: WallpaperRenderer?
        var itemID: String?
        var paused = false
        init(info: ScreenInfo) {
            self.info = info
            self.window = DesktopWindow(frame: info.frame)
        }
    }

    weak var app: AppState?

    @Published private(set) var screens: [ScreenInfo] = []
    @Published var assignments: [String: String] = [:]
    @Published var spanItemID: String?
    @Published var userPaused = false { didSet { updatePauseStates() } }
    @Published var errors: [String: String] = [:]

    private var slots: [String: Slot] = [:]
    private var observers: [Any] = []

    private var settings: AppSettings { app?.settings ?? AppSettings() }
    private var library: LibraryStore? { app?.library }

    // MARK: Экраны

    func setup() {
        rebuildScreens()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildScreens() }
        })
    }

    static func screenInfo(_ s: NSScreen) -> ScreenInfo {
        let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        var key = "display-\(id)"
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let str = CFUUIDCreateString(nil, uuid) as String? {
            key = str
        }
        return ScreenInfo(key: key, name: s.localizedName, frame: s.frame, cgBounds: CGDisplayBounds(id), displayID: id)
    }

    func rebuildScreens() {
        let infos = NSScreen.screens.map(Self.screenInfo)
        guard infos != screens || slots.isEmpty else { return }
        for slot in slots.values {
            slot.renderer?.stop()
            slot.window.orderOut(nil)
        }
        slots.removeAll()
        screens = infos
        for info in infos { slots[info.key] = Slot(info: info) }
        refresh(force: true)
    }

    var unionFrame: CGRect { screens.reduce(CGRect.null) { $0.union($1.frame) } }

    func desiredItem(for key: String) -> String? {
        settings.spanMode ? spanItemID : assignments[key]
    }

    var primaryItemID: String? { screens.first.flatMap { desiredItem(for: $0.key) } }

    var inUse: Set<String> {
        Set(screens.compactMap { desiredItem(for: $0.key) })
    }

    // MARK: Назначение обоев

    func apply(_ id: String?, screen: String?) {
        if settings.spanMode {
            spanItemID = id
        } else if let screen {
            assignments[screen] = id
        } else {
            for s in screens { assignments[s.key] = id }
        }
        app?.saveState()
        refresh()
    }

    func itemRemoved(_ id: String) {
        for (k, v) in assignments where v == id { assignments[k] = nil }
        if spanItemID == id { spanItemID = nil }
        app?.saveState()
        refresh()
    }

    func refresh(force: Bool = false) {
        for info in screens {
            guard let slot = slots[info.key] else { continue }
            let want = desiredItem(for: info.key)
            if !force && want == slot.itemID { continue }
            load(want, into: slot)
        }
        updatePauseStates()
        applyVolume()
    }

    /// Перезапускает рендереры с этими обоями (после правки кода/сцены).
    func reload(itemID: String) {
        for slot in slots.values where slot.itemID == itemID { load(itemID, into: slot) }
        updatePauseStates()
        applyVolume()
    }

    func updateProperties(_ item: WallpaperItem) {
        for slot in slots.values where slot.itemID == item.id { slot.renderer?.applyProperties(item.properties) }
    }

    private func load(_ itemID: String?, into slot: Slot) {
        let old = slot.renderer
        slot.itemID = itemID
        slot.renderer = nil
        slot.paused = false

        guard let id = itemID, let item = library?.item(id) else {
            old?.stop(); old?.view.removeFromSuperview()
            slot.window.orderOut(nil)
            return
        }
        errors[id] = nil
        let r = RendererFactory.make(item: item) { [weak self] msg in
            self?.errors[id] = msg
        }
        let v = r.view
        if settings.spanMode {
            let u = unionFrame
            v.frame = CGRect(x: u.minX - slot.info.frame.minX, y: u.minY - slot.info.frame.minY, width: u.width, height: u.height)
            v.autoresizingMask = []
        } else {
            v.frame = slot.window.container.bounds
            v.autoresizingMask = [.width, .height]
        }
        v.alphaValue = 0
        slot.window.container.addSubview(v)
        slot.window.orderFrontRegardless()
        r.setFPS(settings.fpsLimit)
        r.applyProperties(item.properties)
        if let a = app?.ambient { r.setAmbient((settings.ambientEnabled ? a : AmbientState()).js) }
        if let i = app?.sysInfo.info, !i.isEmpty { r.setInfo(Self.json(i)) }
        r.start()
        slot.renderer = r

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.7
            v.animator().alphaValue = 1
        }, completionHandler: {
            MainActor.assumeIsolated {
                old?.stop()
                old?.view.removeFromSuperview()
            }
        })

        if let lib = library, lib.needsPreview(item) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak r, weak lib] in
                MainActor.assumeIsolated {
                    r?.snapshot { img in
                        if let img, let lib, lib.needsPreview(item) { lib.savePreview(img, for: id) }
                    }
                }
            }
        }
    }

    func snapshotActive(itemID: String, done: @escaping (NSImage?) -> Void) {
        guard let r = slots.values.first(where: { $0.itemID == itemID })?.renderer else { done(nil); return }
        r.snapshot(done)
    }

    // MARK: Пауза, звук, FPS

    func applySettings() {
        for slot in slots.values { slot.renderer?.setFPS(settings.fpsLimit) }
        applyVolume()
        updatePauseStates()
    }

    func applyVolume() {
        let v: Float = settings.muted ? 0 : Float(settings.volume)
        for (i, info) in screens.enumerated() {
            slots[info.key]?.renderer?.setVolume(i == 0 ? v : 0)
        }
    }

    func updatePauseStates() {
        guard let m = app?.monitor else { return }
        let s = settings
        let global = userPaused
            || (s.pauseOnLock && (m.isLocked || m.isAsleep))
            || (s.pauseOnBattery && m.onBattery)
            || (s.pauseWhenAppFocused && m.otherAppFocused)
        for (key, slot) in slots {
            let p = global
                || (s.pauseOnFullscreen && m.fullscreenScreens.contains(key))
                || (s.pauseOnMaximized && m.maximizedScreens.contains(key))
                || (s.pauseWhenCovered && m.coveredScreens.contains(key))
            if p != slot.paused {
                slot.paused = p
                slot.renderer?.setPaused(p)
                if ProcessInfo.processInfo.environment["LW_DEBUG"] != nil {
                    NSLog("LW pause=%@ otherAppFocused=%@ front=%@", p ? "yes" : "no", m.otherAppFocused ? "yes" : "no",
                          NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")
                }
            }
        }
        let active = anyActive
        app?.sysInfo.setActive(active)
        app?.mouse.setActive(active)
    }

    // MARK: Живые данные (виджеты, время суток, погода)

    static func json(_ d: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: d), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    func pushInfo(_ d: [String: String]) {
        let j = Self.json(d)
        for slot in slots.values where !slot.paused { slot.renderer?.setInfo(j) }
    }

    func pushAmbient(_ a: AmbientState) {
        let j = (settings.ambientEnabled ? a : AmbientState()).js
        for slot in slots.values { slot.renderer?.setAmbient(j) }
    }

    /// Есть ли сейчас хоть одни видимые (не на паузе) обои.
    var anyActive: Bool { slots.values.contains { $0.renderer != nil && !$0.paused } }

    // MARK: Ввод

    func pushAudio(_ spectrum: [Float]) {
        for slot in slots.values where !slot.paused { slot.renderer?.updateAudio(spectrum) }
    }

    func handleMouse(_ kind: MouseKind, at p: NSPoint) {
        if kind == .move && !settings.mouseInteraction { return }
        let span = settings.spanMode
        let union = unionFrame
        for info in screens {
            guard let slot = slots[info.key], let r = slot.renderer, !slot.paused else { continue }
            if !span && !info.frame.contains(p) { continue }
            let ref = span ? union : info.frame
            let local = CGPoint(x: p.x - ref.minX, y: ref.maxY - p.y)
            r.mouse(kind, local)
        }
    }

    func shutdown() {
        for slot in slots.values { slot.renderer?.stop(); slot.window.orderOut(nil) }
    }
}
