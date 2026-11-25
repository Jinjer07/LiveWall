import AppKit
import AVFoundation
import QuartzCore

enum MouseKind { case move, down, up }

@MainActor
protocol WallpaperRenderer: AnyObject {
    var view: NSView { get }
    func start()
    func stop()
    func setPaused(_ paused: Bool)
    func setVolume(_ volume: Float)
    func setFPS(_ fps: Int)
    func setSmartFPS(_ idle: Int)
    func applyProperties(_ props: [WallpaperProperty])
    func updateAudio(_ spectrum: [Float])
    func mouse(_ kind: MouseKind, _ p: CGPoint)
    func snapshot(_ done: @escaping (NSImage?) -> Void)
    func setInfo(_ json: String)
    func setAmbient(_ json: String)
}

extension WallpaperRenderer {
    func setFPS(_ fps: Int) {}
    /// Умный FPS: в покое не больше idle кадров/с (0 — выключено), при активности — до лимита.
    func setSmartFPS(_ idle: Int) {}
    func updateAudio(_ spectrum: [Float]) {}
    func mouse(_ kind: MouseKind, _ p: CGPoint) {}
    func setInfo(_ json: String) {}
    func setAmbient(_ json: String) {}
}

@MainActor
enum RendererFactory {
    static func make(item: WallpaperItem, nativeScenes: Bool = true, onError: @escaping (String) -> Void) -> WallpaperRenderer {
        let ext = item.entryURL.pathExtension.lowercased()
        let r: WallpaperRenderer
        switch item.type {
        case .video:
            r = FileKinds.avPlayable.contains(ext) ? VideoRenderer(item: item) : WebRenderer(item: item, mode: .media("video"))
        case .image:
            r = (ext == "gif" || ext == "webp") ? WebRenderer(item: item, mode: .media("image")) : ImageRenderer(item: item, slideshow: false)
        case .slideshow:
            r = ImageRenderer(item: item, slideshow: true)
        case .web:
            r = WebRenderer(item: item, mode: .web)
        case .shader:
            r = WebRenderer(item: item, mode: .shader)
        case .scene:
            // Сцены — на Metal; если Metal недоступен или scene.json не читается, — прежний WebKit-рантайм
            if nativeScenes, let m = MetalSceneRenderer.make(item: item) {
                m.onError = onError
                r = m
            } else {
                r = WebRenderer(item: item, mode: .scene)
            }
        }
        (r as? WebRenderer)?.onError = onError
        return r
    }
}

/// NSView, которая держит подслои по размеру своих границ.
final class LayerHostView: NSView {
    var hosted: [CALayer] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in hosted { l.frame = bounds }
        CATransaction.commit()
    }
    func host(_ l: CALayer) {
        l.frame = bounds
        layer?.addSublayer(l)
        hosted.append(l)
    }
}

func gravity(_ fill: String?) -> AVLayerVideoGravity {
    switch fill {
    case "fit": return .resizeAspect
    case "stretch": return .resize
    default: return .resizeAspectFill
    }
}

func contentsGravity(_ fill: String?) -> CALayerContentsGravity {
    switch fill {
    case "fit": return .resizeAspect
    case "stretch": return .resize
    default: return .resizeAspectFill
    }
}

// MARK: - Видео (AVFoundation, бесшовный цикл)

@MainActor
final class VideoRenderer: WallpaperRenderer {
    private let host = LayerHostView(frame: .zero)
    var view: NSView { host }
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let playerLayer = AVPlayerLayer()
    private let url: URL
    private var rate: Float = 1
    private var paused = false

    init(item: WallpaperItem) {
        url = item.entryURL
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        host.host(playerLayer)
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
    }

    func start() {
        let templ = AVPlayerItem(asset: AVURLAsset(url: url))
        looper = AVPlayerLooper(player: player, templateItem: templ)
        player.defaultRate = rate
        if !paused { player.play() }
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }

    func setPaused(_ p: Bool) {
        paused = p
        if p { player.pause() } else { player.play(); player.rate = rate }
    }

    func setVolume(_ v: Float) {
        player.volume = v
        player.isMuted = v <= 0
    }

    func applyProperties(_ props: [WallpaperProperty]) {
        rate = Float(props.value("rate")?.double ?? 1)
        player.defaultRate = rate
        if !paused && player.rate != 0 { player.rate = rate }
        playerLayer.videoGravity = gravity(props.value("fill")?.string)
    }

    func snapshot(_ done: @escaping (NSImage?) -> Void) {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        let t = player.currentTime()
        Task {
            let img = try? await gen.image(at: t.isValid ? t : .zero).image
            done(img.map { NSImage(cgImage: $0, size: .zero) })
        }
    }
}

// MARK: - Картинка и слайдшоу

@MainActor
final class ImageRenderer: WallpaperRenderer {
    private let host = LayerHostView(frame: .zero)
    var view: NSView { host }
    private let imageLayer = CALayer()
    private let item: WallpaperItem
    private let slideshow: Bool
    private var files: [URL] = []
    private var index = 0
    private var timer: Timer?
    private var interval: Double = 30
    private var transition: Double = 1.5
    private var shuffle = false
    private var paused = false
    private var lastSwitch = Date()

    init(item: WallpaperItem, slideshow: Bool) {
        self.item = item
        self.slideshow = slideshow
        imageLayer.contentsGravity = .resizeAspectFill
        host.host(imageLayer)
    }

    func start() {
        timer?.invalidate(); timer = nil
        files = slideshow ? FileKinds.images(in: item.folderURL) : [item.entryURL]
        if shuffle { files.shuffle() }
        index = 0
        show(animated: false)
        if slideshow {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    private func tick() {
        guard !paused, files.count > 1, Date().timeIntervalSince(lastSwitch) >= interval else { return }
        index = (index + 1) % files.count
        show(animated: true)
    }

    private func show(animated: Bool) {
        guard index < files.count else { return }
        lastSwitch = Date()
        let url = files[index]
        var maxPx: CGFloat = 3000
        for s in NSScreen.screens {
            let side: CGFloat = Swift.max(s.frame.width, s.frame.height) * s.backingScaleFactor * 1.2
            maxPx = Swift.max(maxPx, side)
        }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPx,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return }
        if animated && transition > 0 {
            let t = CATransition()
            t.type = .fade
            t.duration = transition
            imageLayer.add(t, forKey: "fade")
        }
        imageLayer.contents = cg
    }

    func stop() { timer?.invalidate(); timer = nil }
    func setPaused(_ p: Bool) { paused = p }
    func setVolume(_ v: Float) {}

    func applyProperties(_ props: [WallpaperProperty]) {
        imageLayer.contentsGravity = contentsGravity(props.value("fill")?.string)
        interval = max(1, props.value("interval")?.double ?? 30)
        transition = props.value("transition")?.double ?? 1.5
        let sh = props.value("shuffle")?.bool ?? false
        if sh != shuffle { shuffle = sh; if !files.isEmpty { start() } }
    }

    func snapshot(_ done: @escaping (NSImage?) -> Void) {
        if let c = imageLayer.contents { done(NSImage(cgImage: c as! CGImage, size: .zero)) } else { done(nil) }
    }
}
