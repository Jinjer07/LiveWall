import AppKit
import IOKit.ps

// MARK: - Окна поверх обоев

enum WindowScan {
    struct Win { let bounds: CGRect; let layer: Int; let pid: pid_t; let owner: String }

    static func onScreenWindows() -> [Win] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [Win] = []
        for info in list {
            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            guard pid != me else { continue }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.01,
                  let bd = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bd) else { continue }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            out.append(Win(bounds: rect, layer: layer, pid: pid, owner: owner))
        }
        return out
    }

    /// Клик пришёлся на рабочий стол (нет чужих окон в этой точке)?
    static func isDesktop(at p: NSPoint) -> Bool {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let cg = CGPoint(x: p.x, y: primaryH - p.y)
        return !onScreenWindows().contains { $0.layer >= 0 && $0.bounds.contains(cg) }
    }
}

// MARK: - Мониторинг: полноэкранные приложения, батарея, блокировка, сон

@MainActor
final class PerformanceMonitor {
    private(set) var fullscreenScreens: Set<String> = []
    private(set) var maximizedScreens: Set<String> = []
    /// Экраны, где рабочий стол закрыт окнами на ≥85% — обои не видны, рисовать незачем.
    private(set) var coveredScreens: Set<String> = []
    private(set) var onBattery = false
    private(set) var isLocked = false
    private(set) var isAsleep = false
    /// Активна другая программа (не рабочий стол/Finder и не сам LiveWall).
    private(set) var otherAppFocused = false

    static func isOtherAppFrontmost() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let desktopLike: Set<String> = ["com.apple.finder", Bundle.main.bundleIdentifier ?? "com.local.livewall"]
        return !desktopLike.contains(front.bundleIdentifier ?? "")
    }

    var onChange: (() -> Void)?
    var screensProvider: (() -> [WallpaperEngine.ScreenInfo])?

    private var timer: Timer?
    private var observers: [(NotificationCenter, Any)] = []

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        let dn = DistributedNotificationCenter.default()
        func on(_ c: NotificationCenter, _ name: Notification.Name, _ f: @escaping (PerformanceMonitor) -> Void) {
            let o = c.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { f(self); self.onChange?() } }
            }
            observers.append((c, o))
        }
        on(ws, NSWorkspace.screensDidSleepNotification) { $0.isAsleep = true }
        on(ws, NSWorkspace.screensDidWakeNotification) { $0.isAsleep = false }
        on(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.isLocked = true }
        on(ws, NSWorkspace.sessionDidBecomeActiveNotification) { $0.isLocked = false }
        on(dn, Notification.Name("com.apple.screenIsLocked")) { $0.isLocked = true }
        on(dn, Notification.Name("com.apple.screenIsUnlocked")) { $0.isLocked = false }
        on(ws, NSWorkspace.activeSpaceDidChangeNotification) { $0.check(notify: false) }
        on(ws, NSWorkspace.didActivateApplicationNotification) { $0.check(notify: false) }
        check()
    }

    func check(notify: Bool = true) {
        let screens = screensProvider?() ?? []
        let wins = WindowScan.onScreenWindows().filter { $0.layer == 0 && $0.owner != "Dock" && $0.owner != "Window Server" }
        var full = Set<String>(), maxed = Set<String>(), covered = Set<String>()
        for s in screens {
            // Сетка 24×16 точек: доля точек, закрытых хоть одним окном.
            var hit = 0
            let cols = 24, rows = 16
            for cx in 0..<cols {
                for cy in 0..<rows {
                    let pt = CGPoint(x: s.cgBounds.minX + s.cgBounds.width * (CGFloat(cx) + 0.5) / CGFloat(cols),
                                     y: s.cgBounds.minY + s.cgBounds.height * (CGFloat(cy) + 0.5) / CGFloat(rows))
                    if wins.contains(where: { $0.bounds.contains(pt) }) { hit += 1 }
                }
            }
            if Double(hit) / Double(cols * rows) >= 0.85 { covered.insert(s.key) }
            let area = s.cgBounds.width * s.cgBounds.height
            guard area > 0 else { continue }
            for w in wins {
                let inter = w.bounds.intersection(s.cgBounds)
                guard !inter.isNull else { continue }
                let k = inter.width * inter.height / area
                if k >= 0.99 { full.insert(s.key) }
                if k >= 0.85 { maxed.insert(s.key) }
            }
        }
        var battery = false
        if let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(snap)?.takeRetainedValue() as String? {
            battery = type == "Battery Power"
        }
        let focused = Self.isOtherAppFrontmost()
        let changed = full != fullscreenScreens || maxed != maximizedScreens || battery != onBattery || covered != coveredScreens
            || focused != otherAppFocused
        fullscreenScreens = full; maximizedScreens = maxed; onBattery = battery; coveredScreens = covered; otherAppFocused = focused
        if changed && notify { onChange?() }
        if changed && !notify { onChange?() }
    }
}

// MARK: - Мышь
// Положение курсора опрашивается таймером — это не требует разрешений macOS.
// Глобальный перехват кликов (может запросить «Универсальный доступ») включается только по настройке.

@MainActor
final class MouseTracker {
    var handler: ((MouseKind, NSPoint) -> Void)?
    var clicksEnabled = false { didSet { updateClickMonitor() } }
    private var pollTimer: Timer?
    private var clickMonitor: Any?
    private var lastPoint = NSPoint(x: -1, y: -1)
    private var downOnDesktop = false
    private var running = false

    private var wallpaperActive = true

    /// Опрос курсора нужен только пока обои видны и не на паузе.
    func setActive(_ active: Bool) {
        guard active != wallpaperActive else { return }
        wallpaperActive = active
        if running { stop(); start() }
    }

    func start() {
        running = true
        if pollTimer == nil && wallpaperActive {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 25.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
        }
        updateClickMonitor()
    }

    func stop() {
        running = false
        pollTimer?.invalidate(); pollTimer = nil
        updateClickMonitor()
    }

    private func poll() {
        let p = NSEvent.mouseLocation
        guard p != lastPoint else { return }
        lastPoint = p
        handler?(.move, p)
    }

    private func updateClickMonitor() {
        let want = running && clicksEnabled
        if want && clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] e in
                let t = e.type
                MainActor.assumeIsolated { self?.click(t) }
            }
        } else if !want, let m = clickMonitor {
            NSEvent.removeMonitor(m); clickMonitor = nil
        }
    }

    private func click(_ type: NSEvent.EventType) {
        let p = NSEvent.mouseLocation
        if type == .leftMouseDown {
            guard WindowScan.isDesktop(at: p) else { downOnDesktop = false; return }
            downOnDesktop = true
            handler?(.down, p)
        } else if type == .leftMouseUp, downOnDesktop {
            downOnDesktop = false
            handler?(.up, p)
        }
    }
}

// MARK: - Автозапуск (LaunchAgent)

enum LoginItem {
    static let label = "com.local.livewall"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func set(_ on: Bool) {
        if on {
            guard let exe = Bundle.main.executablePath else { return }
            let dict: [String: Any] = [
                "Label": label,
                "ProgramArguments": [exe, "--background"],
                "RunAtLoad": true,
                "ProcessType": "Interactive",
                "LimitLoadToSessionType": "Aqua",
            ]
            try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let d = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
                try? d.write(to: plistURL)
            }
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }
}
