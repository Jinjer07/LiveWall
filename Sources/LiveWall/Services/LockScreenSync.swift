import AppKit
import AVFoundation

/// Экран блокировки macOS показывает системную картинку рабочего стола, а живые обои
/// LiveWall рисуются поверх неё в своём окне. Чтобы на экране блокировки были те же обои,
/// после каждой смены обоев снимаем стоп-кадр в разрешении экрана и ставим его системной картинкой.
/// На рабочем столе её не видно — она под окном LiveWall.
@MainActor
final class LockScreenSync {
    weak var app: AppState?

    private static let dir = Paths.root.appendingPathComponent("LockScreen", isDirectory: true)
    private var pending: [String: DispatchWorkItem] = [:]
    /// Что уже стоит системной картинкой на каждом экране, чтобы не переснимать одно и то же.
    private var applied: [String: String] = [:]

    private var enabled: Bool { app?.settings.lockScreenSync ?? false }

    /// Вызывается после загрузки обоев на экран. Ждём, пока рендерер нарисует первые кадры.
    func schedule(screenKey: String, itemID: String?, delay: TimeInterval = 4) {
        pending[screenKey]?.cancel()
        guard enabled, let itemID, applied[screenKey] != itemID else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.capture(screenKey: screenKey, itemID: itemID) }
        }
        pending[screenKey] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Обои перерисованы после правки (редактор сцен, свойства) — кадр нужно снять заново.
    func invalidate(itemID: String) {
        for (k, v) in applied where v == itemID { applied[k] = nil }
    }

    /// Настройку включили: синхронизируем все экраны сразу.
    func syncAll() {
        applied = [:]
        guard let engine = app?.engine else { return }
        for s in engine.screens { schedule(screenKey: s.key, itemID: engine.desiredItem(for: s.key), delay: 0.5) }
    }

    private func capture(screenKey: String, itemID: String) {
        pending[screenKey] = nil
        guard enabled, let app, let item = app.library.item(itemID),
              app.engine.desiredItem(for: screenKey) == itemID,          // обои успели смениться — не наш кадр
              let screen = NSScreen.screens.first(where: { WallpaperEngine.screenInfo($0).key == screenKey }) else { return }
        let px = CGSize(width: screen.frame.width * screen.backingScaleFactor, height: screen.frame.height * screen.backingScaleFactor)

        switch item.type {
        case .image:
            // Сама картинка — в полном разрешении, без снимка экрана
            set(fileImage: item.entryURL, item: item, screen: screen, key: screenKey)
        case .video:
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: item.entryURL))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = px
            Task { @MainActor in
                if let cg = try? await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image {
                    self.write(NSImage(cgImage: cg, size: .zero), item: item, screen: screen, key: screenKey)
                } else {
                    self.snapshot(item: item, screen: screen, key: screenKey)   // webm и т. п. — снимок рендерера
                }
            }
        default:
            snapshot(item: item, screen: screen, key: screenKey)
        }
    }

    private func snapshot(item: WallpaperItem, screen: NSScreen, key: String) {
        app?.engine.snapshotActive(itemID: item.id) { [weak self] img in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let img, img.isValid {
                    self.write(img, item: item, screen: screen, key: key)
                } else if let p = item.previewURL, FileManager.default.fileExists(atPath: p.path) {
                    self.set(fileImage: p, item: item, screen: screen, key: key)   // запасной вариант — обложка
                }
            }
        }
    }

    private func write(_ img: NSImage, item: WallpaperItem, screen: NSScreen, key: String) {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return }
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        // Новое имя файла каждый раз: macOS кэширует картинку рабочего стола по пути
        let url = Self.dir.appendingPathComponent("\(Self.safe(key))-\(UUID().uuidString.prefix(8)).jpg")
        guard (try? jpeg.write(to: url, options: .atomic)) != nil else { return }
        set(fileImage: url, item: item, screen: screen, key: key)
    }

    private func set(fileImage url: URL, item: WallpaperItem, screen: NSScreen, key: String) {
        guard enabled, app?.engine.desiredItem(for: key) == item.id else { return }
        let opts: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: opts)
            applied[key] = item.id
            cleanup(key: key, keep: url)
        } catch {
            if ProcessInfo.processInfo.environment["LW_DEBUG"] != nil { NSLog("LW lock screen: %@", error.localizedDescription) }
        }
    }

    /// Старые стоп-кадры этого экрана больше не нужны.
    private func cleanup(key: String, keep: URL) {
        let prefix = Self.safe(key) + "-"
        guard let files = try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.lastPathComponent.hasPrefix(prefix) && f != keep {
            try? FileManager.default.removeItem(at: f)
        }
    }

    private static func safe(_ key: String) -> String {
        String(key.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }
}
