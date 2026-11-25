import AppKit
import Metal
import QuartzCore
import CoreText
import ImageIO

// MARK: - Нативный рендер сцен на Metal
//
// Повторяет рантайм scene.html (WebGL 2) без веб-движка: те же формулы раскладки, параллакса,
// частиц, цветокоррекции и режимов наложения. Нет отдельного процесса WebKit, моста JavaScript
// и копирования кадра через веб-компоновщик — сцена рисуется прямо в CAMetalLayer.
// Редактор сцен по-прежнему работает на WebKit (там нужны выделение и перетаскивание слоёв).

private let sceneShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct QuadV { float4 a; float4 b; };          // a: res.xy, center.xy; b: size.xy, rot
struct QuadF { float4 tint; float4 wave; float4 hsbo; float4 misc; float4 texel; };
// wave: amp, freq, speed, vertical; hsbo: hue, sat, bright, opacity; misc: time, blur, feather, plainColor
struct QOut { float4 pos [[position]]; float2 uv; };

constant float2 corners[6] = { float2(-.5,-.5), float2(.5,-.5), float2(-.5,.5), float2(-.5,.5), float2(.5,-.5), float2(.5,.5) };

vertex QOut quadV(uint vid [[vertex_id]], constant QuadV& u [[buffer(0)]]) {
    float2 a = corners[vid];
    float2 p = a * u.b.xy;
    float c = cos(u.b.z), s = sin(u.b.z);
    p = float2(p.x * c - p.y * s, p.x * s + p.y * c) + u.a.zw;
    float2 q = p / u.a.xy * 2.0 - 1.0;
    QOut o; o.pos = float4(q.x, -q.y, 0, 1); o.uv = a + 0.5; return o;
}

float3 rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0/3.0, 2.0/3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y); float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}
float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

fragment float4 quadF(QOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler sm [[sampler(0)]],
                      constant QuadF& u [[buffer(0)]]) {
    float2 uv = in.uv;
    if (u.wave.x > 0.0) {
        if (u.wave.w > 0.5) uv.x += sin(uv.y * u.wave.y * 6.2831 + u.misc.x * u.wave.z) * u.wave.x * 0.02;
        else uv.y += sin(uv.x * u.wave.y * 6.2831 + u.misc.x * u.wave.z) * u.wave.x * 0.02;
    }
    float4 c;
    float3 straight = float3(0.0);    // цвет без предумножения на прозрачность (как текстуры в WebGL)
    if (u.misc.w > 0.5) { c = float4(1.0); straight = float3(1.0); }
    else if (u.misc.y > 0.0) {
        // Размытие для свечения: WebGL усреднял «чистые» цвета и прозрачность по отдельности
        c = float4(0.0);
        for (int i = -2; i <= 2; i++) for (int j = -2; j <= 2; j++) {
            float4 t = tex.sample(sm, uv + float2(i, j) * u.texel.xy * u.misc.y);
            c.a += t.a;
            if (t.a > 0.0001) straight += t.rgb / t.a;
        }
        c.a /= 25.0; straight /= 25.0;
    } else {
        c = tex.sample(sm, uv);
        straight = c.a > 0.0001 ? c.rgb / c.a : float3(0.0);
    }
    float3 rgb = straight;
    if (u.hsbo.x != 0.0 || u.hsbo.y != 1.0) {
        float3 h = rgb2hsv(rgb); h.x = fract(h.x + u.hsbo.x); h.y = clamp(h.y * u.hsbo.y, 0.0, 1.0); rgb = hsv2rgb(h);
    }
    rgb *= u.hsbo.z * u.tint.rgb;
    float a = c.a * u.hsbo.w * u.tint.a;
    float f = u.misc.z;
    if (f > 0.0) {
        a *= smoothstep(0.0, f, in.uv.x) * smoothstep(0.0, f, 1.0 - in.uv.x) * smoothstep(0.0, f, in.uv.y) * smoothstep(0.0, f, 1.0 - in.uv.y);
    }
    return float4(rgb * a, a);
}

struct PIn { packed_float2 p; float s; float a; float m; };
struct PU { float4 res; float4 c1; float4 c2; };         // res.xy; c1.rgb + shape; c2.rgb + useTex
struct POut { float4 pos [[position]]; float size [[point_size]]; float a; float m; };

vertex POut partV(uint vid [[vertex_id]], device const PIn* v [[buffer(0)]], constant PU& u [[buffer(1)]]) {
    PIn d = v[vid];
    float2 q = float2(d.p) / u.res.xy * 2.0 - 1.0;
    POut o; o.pos = float4(q.x, -q.y, 0, 1); o.size = d.s; o.a = d.a; o.m = d.m; return o;
}

fragment float4 partF(POut in [[stage_in]], float2 pc [[point_coord]], texture2d<float> tex [[texture(0)]],
                      sampler sm [[sampler(0)]], constant PU& u [[buffer(0)]]) {
    float2 d = pc - 0.5; float r = length(d);
    float3 col = mix(u.c1.rgb, u.c2.rgb, in.m);
    float a;
    int shape = int(u.c1.w + 0.5);
    if (u.c2.w > 0.5) { float4 t = tex.sample(sm, pc); col *= (t.a > 0.0001 ? t.rgb / t.a : float3(0.0)); a = t.a; }
    else if (shape == 1) { a = (1.0 - smoothstep(0.40, 0.5, r)) * (0.35 + 0.65 * smoothstep(0.25, 0.48, r)); }
    else if (shape == 2) { a = max(0.0, 1.0 - abs(d.x) * 10.0) * max(0.0, 1.0 - abs(d.y) * 2.0); }
    else { a = pow(max(0.0, 1.0 - r * 2.0), 1.6); }
    a *= in.a;
    return float4(col * a, a);
}
"""

private struct QuadV { var a: SIMD4<Float>; var b: SIMD4<Float> }
private struct QuadF { var tint: SIMD4<Float>; var wave: SIMD4<Float>; var hsbo: SIMD4<Float>; var misc: SIMD4<Float>; var texel: SIMD4<Float> }
private struct PU { var res: SIMD4<Float>; var c1: SIMD4<Float>; var c2: SIMD4<Float> }

/// Общие для всех экранов объекты Metal: устройство, очередь, конвейеры.
@MainActor
private final class MetalShared {
    static let shared: MetalShared? = MetalShared()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let sampler: MTLSamplerState
    let white: MTLTexture
    private var quad: [String: MTLRenderPipelineState] = [:]
    private var part: [String: MTLRenderPipelineState] = [:]

    private init?() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { return nil }
        device = d; queue = q
        do {
            let lib = try d.makeLibrary(source: sceneShaderSource, options: nil)
            for mode in ["normal", "add", "screen", "multiply"] {
                quad[mode] = try Self.pipeline(d, lib, "quadV", "quadF", mode)
                part[mode] = try Self.pipeline(d, lib, "partV", "partF", mode)
            }
        } catch {
            NSLog("LiveWall: Metal shaders failed: %@", error.localizedDescription)
            return nil
        }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        guard let s = d.makeSamplerState(descriptor: sd) else { return nil }
        sampler = s
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        guard let w = d.makeTexture(descriptor: td) else { return nil }
        var px: UInt32 = 0xFFFF_FFFF
        w.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        white = w
    }

    private static func pipeline(_ d: MTLDevice, _ lib: MTLLibrary, _ v: String, _ f: String, _ mode: String) throws -> MTLRenderPipelineState {
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: v)
        pd.fragmentFunction = lib.makeFunction(name: f)
        let ca = pd.colorAttachments[0]!
        ca.pixelFormat = .bgra8Unorm
        ca.isBlendingEnabled = true
        // Те же формулы, что gl.blendFunc в scene.html (цвета premultiplied)
        let (src, dst): (MTLBlendFactor, MTLBlendFactor)
        switch mode {
        case "add": (src, dst) = (.one, .one)
        case "screen": (src, dst) = (.one, .oneMinusSourceColor)
        case "multiply": (src, dst) = (.destinationColor, .oneMinusSourceAlpha)
        default: (src, dst) = (.one, .oneMinusSourceAlpha)
        }
        ca.sourceRGBBlendFactor = src; ca.destinationRGBBlendFactor = dst
        ca.sourceAlphaBlendFactor = src; ca.destinationAlphaBlendFactor = dst
        return try d.makeRenderPipelineState(descriptor: pd)
    }

    func quadPipeline(_ mode: String) -> MTLRenderPipelineState { quad[mode] ?? quad["normal"]! }
    func partPipeline(_ mode: String) -> MTLRenderPipelineState { part[mode] ?? part["normal"]! }
}

/// Слой CAMetalLayer, растянутый на вью.
private final class MetalHostView: NSView {
    let metalLayer = CAMetalLayer()
    var onResize: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = metalLayer
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); onResize?() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); onResize?() }
}

@MainActor
final class MetalSceneRenderer: NSObject, WallpaperRenderer {
    var view: NSView { host }
    var onError: ((String) -> Void)?

    private let host = MetalHostView(frame: .zero)
    private let gpu: MetalShared
    private let item: WallpaperItem
    private var scene: SceneDoc
    private let base: URL

    // Состояние, как в scene.html
    private var W: CGFloat = 1, H: CGFloat = 1, DPR: CGFloat = 1, S: CGFloat = 1, OX: CGFloat = 0, OY: CGFloat = 0
    private var time: Double = 0
    private var lastTick: CFTimeInterval?
    private var smoothMouse = CGPoint(x: 0.5, y: 0.5)
    private var rawMouse = CGPoint(x: 0.5, y: 0.5)
    private var au = (bass: 0.0, mid: 0.0, high: 0.0, level: 0.0)
    private var spectrum = [Float](repeating: 0, count: 128)
    private var propParallax = 1.0, propSpeed = 1.0, propQuality = 1.0
    private var info: [String: String] = [:]
    private var ambient = (night: 0.0, golden: 0.0, precip: "none", intensity: 0.0, cloud: 0.0)

    // Кадры
    private var fps = 15, smartIdle = 0
    private var boostUntil: CFTimeInterval = 0
    private var bassAvg = 0.0
    private var paused = false, stopped = false
    private var needFrames = 0
    private var timer: DispatchSourceTimer?
    private let inFlight = DispatchSemaphore(value: 3)
    private var frameIndex = 0

    // Ресурсы
    private struct Tex { let t: MTLTexture; let w: Int; let h: Int }
    private var textures: [String: Tex] = [:]
    private var loading: Set<String> = []
    private var failed: Set<String> = []
    private struct TextTex { let tex: Tex; let key: String; let w: CGFloat; let h: CGFloat }
    private var texts: [String: TextTex] = [:]

    private struct Particle { var x = 0.0, y = 0.0, vx = 0.0, vy = 0.0, size = 1.0, life = 1.0, age = 0.0, mix = 0.0, ph = 0.0 }
    private final class System {
        var n: Int; var emitter: String; var p: [Particle]
        var buffers: [MTLBuffer] = []
        init(n: Int, emitter: String, p: [Particle]) { self.n = n; self.emitter = emitter; self.p = p }
    }
    private var systems: [String: System] = [:]

    /// nil — Metal недоступен или сцену не удалось прочитать: тогда используется WebKit.
    static func make(item: WallpaperItem) -> MetalSceneRenderer? {
        guard let gpu = MetalShared.shared,
              let data = try? Data(contentsOf: item.entryURL),
              let doc = try? JSONDecoder().decode(SceneDoc.self, from: data) else { return nil }
        return MetalSceneRenderer(item: item, scene: doc, gpu: gpu)
    }

    private init(item: WallpaperItem, scene: SceneDoc, gpu: MetalShared) {
        self.item = item; self.scene = scene; self.gpu = gpu
        self.base = item.folderURL
        super.init()
        let ml = host.metalLayer
        ml.device = gpu.device
        ml.pixelFormat = .bgra8Unorm
        ml.framebufferOnly = true
        ml.isOpaque = true
        ml.maximumDrawableCount = 3
        ml.allowsNextDrawableTimeout = true
        host.onResize = { [weak self] in MainActor.assumeIsolated { self?.layoutDrawable() } }
        applyProperties(item.properties)
    }

    // MARK: WallpaperRenderer

    func start() {
        stopped = false
        preloadTextures()
        needFrames = 3
        scheduleNext(immediate: true)
    }

    func stop() {
        stopped = true
        timer?.cancel(); timer = nil
    }

    func setPaused(_ p: Bool) {
        paused = p
        if p { needFrames = max(needFrames, 1) }
        lastTick = nil
        scheduleNext(immediate: true)
    }

    func setVolume(_ volume: Float) {}
    func setFPS(_ f: Int) { fps = f > 0 ? f : 60 }
    func setSmartFPS(_ idle: Int) { smartIdle = idle }

    func applyProperties(_ props: [WallpaperProperty]) {
        if let v = props.value("parallax")?.double { propParallax = v }
        if let v = props.value("speed")?.double { propSpeed = v }
        if let v = props.value("quality")?.double { propQuality = v }
        layoutDrawable()
        needFrames = max(needFrames, 2)
    }

    func updateAudio(_ s: [Float]) {
        guard s.count >= 128 else { return }
        spectrum = s
        // Удар в басах — поднимаем частоту кадров (умный FPS)
        var b = 0.0
        for i in 0..<6 { b += Double(s[i] + s[i + 64]) * 0.5 }
        b /= 6
        if smartIdle > 0 && b - bassAvg > 0.12 { boost(0.6) }
        bassAvg += (b - bassAvg) * 0.08
    }

    func mouse(_ kind: MouseKind, _ p: CGPoint) {
        rawMouse = CGPoint(x: p.x / max(1, W), y: p.y / max(1, H))
        boost(1.5)
    }

    func setInfo(_ json: String) {
        guard let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        info = o.mapValues { "\($0)" }
        needFrames = max(needFrames, 1)
    }

    func setAmbient(_ json: String) {
        guard let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        func n(_ k: String) -> Double { (o[k] as? NSNumber)?.doubleValue ?? 0 }
        ambient = (n("night"), n("golden"), o["precip"] as? String ?? "none", n("intensity"), n("cloud"))
        needFrames = max(needFrames, 1)
    }

    func snapshot(_ done: @escaping (NSImage?) -> Void) {
        let w = Int(W * DPR), h = Int(H * DPR)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: max(1, w), height: max(1, h), mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let target = gpu.device.makeTexture(descriptor: td), let cb = gpu.queue.makeCommandBuffer() else { done(nil); return }
        encode(into: target, cb: cb, dt: 0)
        cb.addCompletedHandler { _ in
            let bpr = w * 4
            var bytes = [UInt8](repeating: 0, count: bpr * h)
            target.getBytes(&bytes, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            let img: NSImage? = bytes.withUnsafeMutableBytes { raw -> NSImage? in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                      let cg = ctx.makeImage() else { return nil }
                return NSImage(cgImage: cg, size: .zero)
            }
            DispatchQueue.main.async { done(img) }
        }
        cb.commit()
    }

    // MARK: Планировщик кадров

    private func boost(_ seconds: Double) {
        let until = CACurrentMediaTime() + seconds
        let wasIdle = CACurrentMediaTime() >= boostUntil
        boostUntil = max(boostUntil, until)
        if wasIdle && !paused { scheduleNext(immediate: true) }   // сразу перейти на высокую частоту
    }

    private var currentFPS: Int {
        if CACurrentMediaTime() < boostUntil { return max(fps, 30) }
        return smartIdle > 0 ? min(fps, smartIdle) : fps
    }

    private func scheduleNext(immediate: Bool = false) {
        timer?.cancel(); timer = nil
        guard !stopped else { return }
        if paused && needFrames <= 0 { return }
        // Интервал отсчитываем от начала прошлого кадра, а не от его конца — иначе 60 FPS выходят как 54
        let iv = immediate ? 0.0 : max(0.002, 1.0 / Double(max(1, currentFPS)) - (CACurrentMediaTime() - tickStart))
        // Строгий таймер: обычные таймеры фоновых приложений macOS объединяет, и 60 FPS превращались в 54
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        t.schedule(deadline: .now() + iv, leeway: .microseconds(500))
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        t.resume()
        timer = t
    }

    private var tickStart: CFTimeInterval = 0

    private func tick() {
        timer = nil
        tickStart = CACurrentMediaTime()
        guard !stopped else { return }
        if paused { needFrames -= 1 }
        else if needFrames > 0 { needFrames -= 1 }
        let now = CACurrentMediaTime()
        let rdt = lastTick.map { min(0.1, now - $0) } ?? 0.016
        lastTick = paused ? nil : now
        drawFrame(rdt: rdt)
        if Self.debug {
            fpsCount += 1; drawTime += CACurrentMediaTime() - now
            if now - fpsSince >= 5 {
                NSLog("LW metal fps %.1f, frame %.2f ms, skipped %d (%@)", Double(fpsCount) / (now - fpsSince), drawTime / Double(fpsCount) * 1000, skipped, item.title)
                fpsCount = 0; fpsSince = now; drawTime = 0; skipped = 0
            }
        }
        scheduleNext()
    }
    private static let debug = ProcessInfo.processInfo.environment["LW_DEBUG"] != nil
    private var fpsCount = 0, skipped = 0
    private var drawTime = 0.0
    private var fpsSince = CACurrentMediaTime()

    // MARK: Отрисовка

    private func layoutDrawable() {
        let b = host.bounds.size
        guard b.width > 0, b.height > 0 else { return }
        DPR = CGFloat(max(0.25, min(2, propQuality)))
        let size = CGSize(width: (b.width * DPR).rounded(), height: (b.height * DPR).rounded())
        if host.metalLayer.drawableSize != size {
            host.metalLayer.drawableSize = size
            host.metalLayer.contentsScale = host.window?.backingScaleFactor ?? 2
            texts.removeAll()       // текст рендерится под размер — пересоздадим
            needFrames = max(needFrames, 2)
        }
    }

    private func updateLayout() {
        W = max(1, host.bounds.width); H = max(1, host.bounds.height)
        S = max(W / CGFloat(scene.width), H / CGFloat(scene.height))
        OX = (W - CGFloat(scene.width) * S) / 2; OY = (H - CGFloat(scene.height) * S) / 2
    }

    private func drawFrame(rdt: Double) {
        guard inFlight.wait(timeout: .now()) == .success else { skipped += 1; return }   // GPU не успевает — пропускаем кадр
        layoutDrawable()
        guard let drawable = host.metalLayer.nextDrawable(), let cb = gpu.queue.makeCommandBuffer() else {
            inFlight.signal(); return
        }
        let dt = rdt * propSpeed
        time += dt
        updateAudioBands()
        let k = CGFloat(min(1, rdt * 5))
        smoothMouse.x += (rawMouse.x - smoothMouse.x) * k
        smoothMouse.y += (rawMouse.y - smoothMouse.y) * k
        encode(into: drawable.texture, cb: cb, dt: dt)
        cb.present(drawable)
        let sem = inFlight
        cb.addCompletedHandler { _ in sem.signal() }
        cb.commit()
        frameIndex &+= 1
    }

    private func updateAudioBands() {
        var b = 0.0, m = 0.0, h = 0.0, l = 0.0
        for i in 0..<64 {
            let v = Double(spectrum[i] + spectrum[i + 64]) * 0.5
            l += v
            if i < 6 { b += v } else if i < 26 { m += v } else { h += v }
        }
        au.bass += (b / 6 - au.bass) * 0.35
        au.mid += (m / 20 - au.mid) * 0.35
        au.high += (h / 38 - au.high) * 0.35
        au.level += (l / 64 - au.level) * 0.35
    }

    private func band(_ n: String) -> Double {
        switch n { case "mid": return au.mid; case "high": return au.high; case "level": return au.level; default: return au.bass }
    }

    private func encode(into target: MTLTexture, cb: MTLCommandBuffer, dt: Double) {
        updateLayout()
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        let bg = Self.hex(scene.background)
        rp.colorAttachments[0].clearColor = MTLClearColor(red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setFragmentSamplerState(gpu.sampler, index: 0)
        for L in scene.layers where L.visible {
            switch L.kind {
            case .image:
                if let file = L.file, let t = texture(file) { drawSprite(enc, L, t, Double(t.w), Double(t.h), Self.hex(L.tint)) }
            case .color:
                drawSprite(enc, L, nil, L.width, L.height, Self.hex(L.tint))
            case .text:
                if let te = textTexture(L) { drawSprite(enc, L, te.tex, Double(te.w), Double(te.h), Self.hex(L.textColor)) }
            case .particles:
                drawParticles(enc, L, dt: dt)
            }
        }
        if scene.ambient == true { drawAmbient(enc, dt: dt) }
        enc.endEncoding()
    }

    private struct Xf { var cx: Float; var cy: Float; var sw: Float; var sh: Float; var rot: Float }

    private func xform(_ L: SceneLayer, _ w: Double, _ h: Double) -> Xf {
        let par = L.parallax * propParallax
        let dx = -(Double(smoothMouse.x) - 0.5) * par * 80 * Double(S), dy = -(Double(smoothMouse.y) - 0.5) * par * 80 * Double(S)
        let pulse = 1 + L.audioPulse * band(L.audioBand)
        let ex = 1 + 0.05 * par
        return Xf(cx: Float(Double(OX) + L.x * scene.width * Double(S) + dx),
                  cy: Float(Double(OY) + L.y * scene.height * Double(S) + dy),
                  sw: Float(w * L.scale * Double(S) * ex * pulse), sh: Float(h * L.scale * Double(S) * ex * pulse),
                  rot: Float((L.rotation + L.rotationSpeed * time) * .pi / 180))
    }

    private func quad(_ enc: MTLRenderCommandEncoder, _ t: Tex?, _ X: Xf, blend: String, tint: SIMD4<Float>,
                      opacity: Float, hsb: SIMD3<Float>, wave: SIMD4<Float>, blur: Float, feather: Float) {
        enc.setRenderPipelineState(gpu.quadPipeline(blend))
        var v = QuadV(a: SIMD4(Float(W), Float(H), X.cx, X.cy), b: SIMD4(X.sw, X.sh, X.rot, 0))
        var f = QuadF(tint: tint, wave: wave, hsbo: SIMD4(hsb.x, hsb.y, hsb.z, opacity),
                      misc: SIMD4(Float(time), blur, feather, t == nil ? 1 : 0),
                      texel: SIMD4(1 / Float(max(1, t?.w ?? 1)), 1 / Float(max(1, t?.h ?? 1)), 0, 0))
        enc.setVertexBytes(&v, length: MemoryLayout<QuadV>.stride, index: 0)
        enc.setFragmentBytes(&f, length: MemoryLayout<QuadF>.stride, index: 0)
        enc.setFragmentTexture(t?.t ?? gpu.white, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func drawSprite(_ enc: MTLRenderCommandEncoder, _ L: SceneLayer, _ t: Tex?, _ w: Double, _ h: Double, _ tint: SIMD4<Float>) {
        let X = xform(L, w, h)
        let hsb = SIMD3(Float(L.hue / 360), Float(L.saturation), Float(L.brightness))
        let wave: SIMD4<Float> = L.waveEnabled ? SIMD4(Float(L.waveAmplitude), Float(L.waveFrequency), Float(L.waveSpeed), L.waveVertical ? 1 : 0) : .zero
        let feather = Float(L.feather ?? 0)
        quad(enc, t, X, blend: L.blend, tint: tint, opacity: Float(L.opacity), hsb: hsb, wave: wave, blur: 0, feather: feather)
        if L.glowEnabled {
            let gi = L.glowIntensity * (1 + (L.audioPulse > 0 ? band(L.audioBand) * 2 : 0))
            let G = Xf(cx: X.cx, cy: X.cy, sw: X.sw * 1.03, sh: X.sh * 1.03, rot: X.rot)
            quad(enc, t, G, blend: "add", tint: Self.hex(L.glowColor), opacity: Float(L.opacity * gi), hsb: hsb, wave: wave,
                 blur: Float(max(0.5, L.glowRadius)), feather: feather)
        }
    }

    // MARK: Частицы

    private func rnd(_ a: Double, _ b: Double) -> Double { a + Double.random(in: 0...1) * (b - a) }

    private func spawn(_ L: SceneLayer, _ p: inout Particle, pre: Bool) {
        let dir = (L.pDirection + rnd(-1, 1) * L.pSpread) * .pi / 180, sp = L.pSpeed * rnd(0.6, 1.4)
        p.vx = cos(dir) * sp; p.vy = sin(dir) * sp
        let smin = L.pSizeMin; p.size = rnd(smin, max(smin, L.pSizeMax))
        p.life = max(0.2, L.pLifetime * rnd(0.6, 1)); p.age = pre ? Double.random(in: 0...1) * p.life : 0
        p.mix = Double.random(in: 0...1); p.ph = Double.random(in: 0...6.2832)
        let sw = scene.width, sh = scene.height, m = 40.0
        switch L.pEmitter {
        case "top": p.x = rnd(-m, sw + m); p.y = pre ? rnd(-m, sh) : -m * 0.5
        case "bottom": p.x = rnd(-m, sw + m); p.y = pre ? rnd(0, sh + m) : sh + m * 0.5
        case "point":
            p.x = L.x * sw; p.y = L.y * sh
            if pre { p.x += p.vx * p.age; p.y += p.vy * p.age }
        default: p.x = rnd(0, sw); p.y = rnd(0, sh)
        }
    }

    private func drawParticles(_ enc: MTLRenderCommandEncoder, _ L: SceneLayer, dt: Double) {
        let n = max(0, min(5000, L.pCount))
        var sys = systems[L.id]
        if sys == nil || sys!.n != n || sys!.emitter != L.pEmitter {
            var ps: [Particle] = []
            ps.reserveCapacity(n)
            for _ in 0..<n { var p = Particle(); spawn(L, &p, pre: true); ps.append(p) }
            sys = System(n: n, emitter: L.pEmitter, p: ps)
            systems[L.id] = sys
        }
        guard let s = sys, n > 0 else { return }
        if s.buffers.isEmpty {
            s.buffers = (0..<3).compactMap { _ in gpu.device.makeBuffer(length: max(1, n) * 20, options: .storageModeShared) }
            guard s.buffers.count == 3 else { return }
        }
        let buf = s.buffers[frameIndex % 3]
        let par = L.parallax * propParallax
        let dx = -(Double(smoothMouse.x) - 0.5) * par * 80 * Double(S), dy = -(Double(smoothMouse.y) - 0.5) * par * 80 * Double(S)
        let boostK = 1 + L.pAudio * au.bass * 3, sw = scene.width, sh = scene.height, m = 160.0
        let mx = (Double(rawMouse.x * W) - Double(OX)) / Double(S), my = (Double(rawMouse.y * H) - Double(OY)) / Double(S)
        let g = L.pGravity, wob = L.pWobble, op = L.opacity, sizeK = Double(S * DPR) * (1 + L.pAudio * au.bass)
        let out = buf.contents().bindMemory(to: Float.self, capacity: n * 5)
        let Sd = Double(S)
        for j in 0..<n {
            var p = s.p[j]
            p.age += dt; p.vy += g * dt
            p.x += (p.vx * boostK + sin(time * 1.3 + p.ph) * wob) * dt; p.y += p.vy * boostK * dt
            if L.pMouseRepel {
                let ddx = p.x - mx, ddy = p.y - my, d2 = ddx * ddx + ddy * ddy
                if d2 < 22500 && d2 > 1 { let d = d2.squareRoot(), f = (150 - d) / 150 * 400 * dt; p.x += ddx / d * f; p.y += ddy / d * f }
            }
            if p.age > p.life || p.x < -m || p.x > sw + m || p.y < -m || p.y > sh + m { spawn(L, &p, pre: false) }
            var a = min(1, p.age / (p.life * 0.15), (p.life - p.age) / (p.life * 0.15)); if a < 0 { a = 0 }
            s.p[j] = p
            let o = j * 5
            out[o] = Float(Double(OX) + p.x * Sd + dx); out[o + 1] = Float(Double(OY) + p.y * Sd + dy)
            out[o + 2] = Float(p.size * sizeK); out[o + 3] = Float(a * op); out[o + 4] = Float(p.mix)
        }
        let c1 = Self.hex(L.pColor), c2 = Self.hex(L.pColor2)
        let shape: Float = ["circle": 1, "streak": 2][L.pShape] ?? 0
        var tex: Tex? = nil
        if L.pShape == "image", let f = L.file { tex = texture(f) }
        var u = PU(res: SIMD4(Float(W), Float(H), 0, 0), c1: SIMD4(c1.x, c1.y, c1.z, shape), c2: SIMD4(c2.x, c2.y, c2.z, tex != nil ? 1 : 0))
        enc.setRenderPipelineState(gpu.partPipeline(L.blend))
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<PU>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<PU>.stride, index: 0)
        enc.setFragmentTexture(tex?.t ?? gpu.white, index: 0)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: n)
    }

    // MARK: Время суток и погода

    private static let ambRain: SceneLayer = {
        var L = SceneLayer(name: "rain", kind: .particles)
        L.id = "__amb_rain"; L.pEmitter = "top"; L.pCount = 0; L.pSizeMin = 10; L.pSizeMax = 22; L.pSpeed = 1100; L.pDirection = 95; L.pSpread = 2
        L.pLifetime = 3; L.pGravity = 0; L.pWobble = 0; L.pColor = "#a9c7ff"; L.pColor2 = "#d8e6ff"; L.pShape = "streak"
        L.opacity = 0.55; L.parallax = 0.3; L.blend = "normal"
        return L
    }()
    private static let ambSnow: SceneLayer = {
        var L = SceneLayer(name: "snow", kind: .particles)
        L.id = "__amb_snow"; L.pEmitter = "top"; L.pCount = 0; L.pSizeMin = 2; L.pSizeMax = 7; L.pSpeed = 45; L.pDirection = 90; L.pSpread = 15
        L.pLifetime = 40; L.pGravity = 0; L.pWobble = 22; L.pColor = "#ffffff"; L.pColor2 = "#cfe3ff"; L.pShape = "soft"
        L.opacity = 0.9; L.parallax = 0.4; L.blend = "normal"
        return L
    }()

    private func drawAmbient(_ enc: MTLRenderCommandEncoder, dt: Double) {
        let a = ambient
        if scene.ambientPrecip != false && a.precip != "none" && !a.precip.isEmpty {
            var L = a.precip == "snow" ? Self.ambSnow : Self.ambRain
            L.pCount = Int(((a.precip == "snow" ? 320.0 : 520.0) * max(0.2, a.intensity > 0 ? a.intensity : 0.5)).rounded())
            drawParticles(enc, L, dt: dt)
        }
        let full = Xf(cx: Float(W / 2), cy: Float(H / 2), sw: Float(W), sh: Float(H), rot: 0)
        if a.night > 0.01 || a.cloud > 0.05 {
            let k = Float(1 - 0.12 * a.cloud), n = Float(a.night)
            quad(enc, nil, full, blend: "multiply", tint: SIMD4(k * (1 - 0.48 * n), k * (1 - 0.40 * n), k * (1 - 0.15 * n), 1),
                 opacity: 1, hsb: SIMD3(0, 1, 1), wave: .zero, blur: 0, feather: 0)
        }
        if a.golden > 0.01 {
            quad(enc, nil, full, blend: "add", tint: SIMD4(1, 0.45, 0.18, 1), opacity: Float(0.16 * a.golden),
                 hsb: SIMD3(0, 1, 1), wave: .zero, blur: 0, feather: 0)
        }
    }

    // MARK: Текстуры

    private func preloadTextures() {
        for L in scene.layers {
            if let f = L.file, L.kind == .image || (L.kind == .particles && L.pShape == "image") { _ = texture(f) }
        }
    }

    private func texture(_ file: String) -> Tex? {
        if let t = textures[file] { return t }
        guard !loading.contains(file), !failed.contains(file) else { return nil }
        loading.insert(file)
        let url = base.appendingPathComponent(file)
        let device = gpu.device, queue = gpu.queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tex = Self.loadTexture(url, device: device, queue: queue)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.loading.remove(file)
                    if let tex {
                        self.textures[file] = tex
                        self.needFrames = max(self.needFrames, 2)
                        if self.paused { self.scheduleNext(immediate: true) }
                    } else {
                        self.failed.insert(file)
                        self.onError?(tr("Не удалось загрузить %@", file))
                    }
                }
            }
        }
        return nil
    }

    /// Картинка → текстура BGRA (premultiplied) с mip-уровнями.
    nonisolated private static func loadTexture(_ url: URL, device: MTLDevice, queue: MTLCommandQueue) -> Tex? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        var w = img.width, h = img.height
        let maxSide = 8192
        if max(w, h) > maxSide { let k = Double(maxSide) / Double(max(w, h)); w = Int(Double(w) * k); h = Int(Double(h) * k) }
        let bpr = w * 4
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: true)
        td.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: td) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: bpr)
        if t.mipmapLevelCount > 1, let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: t)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        return Tex(t: t, w: w, h: h)
    }

    // MARK: Текст

    private static func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    private func textString(_ s: String) -> String {
        var r = s
        for k in ["cpu", "ram", "battery", "charging", "track", "artist", "event", "eventTime", "temp", "weather", "city"] {
            let token = "{\(k)}"
            if r.contains(token) { r = r.replacingOccurrences(of: token, with: info[k] ?? "—") }
        }
        guard r.contains("{") else { return r }
        let d = Date(), c = Calendar.current.dateComponents([.hour, .minute, .second, .year], from: d)
        let loc = Locale(identifier: Loc.lang == "en" ? "en_US" : "ru_RU")
        func fmt(_ tpl: String) -> String {
            let f = DateFormatter(); f.locale = loc; f.setLocalizedDateFormatFromTemplate(tpl); return f.string(from: d)
        }
        if r.contains("{time:s}") { r = r.replacingOccurrences(of: "{time:s}", with: "\(Self.pad(c.hour ?? 0)):\(Self.pad(c.minute ?? 0)):\(Self.pad(c.second ?? 0))") }
        if r.contains("{time}") { r = r.replacingOccurrences(of: "{time}", with: "\(Self.pad(c.hour ?? 0)):\(Self.pad(c.minute ?? 0))") }
        if r.contains("{date}") { r = r.replacingOccurrences(of: "{date}", with: fmt("dMMMM")) }
        if r.contains("{weekday}") { r = r.replacingOccurrences(of: "{weekday}", with: fmt("EEEE")) }
        if r.contains("{year}") { r = r.replacingOccurrences(of: "{year}", with: String(c.year ?? 0)) }
        return r
    }

    private static func weight(_ w: String) -> NSFont.Weight {
        switch w {
        // Сверено с тем, как WebKit рисует -apple-system на canvas: его 200 заметно плотнее «Thin»
        case "100": return .thin
        case "200", "300": return .light
        case "400", "normal": return .regular
        case "500": return .medium
        case "700", "bold": return .bold
        case "800": return .heavy
        case "900": return .black
        default: return .semibold
        }
    }

    private func textTexture(_ L: SceneLayer) -> TextTex? {
        let s = textString(L.text)
        let px = max(4, L.fontSize * Double(S * DPR))
        let key = "\(s)|\(String(format: "%.1f", px))|\(L.fontWeight)"
        if let e = texts[L.id], e.key == key { return e }
        let font = NSFont.systemFont(ofSize: CGFloat(px), weight: Self.weight(L.fontWeight))
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let lines = s.components(separatedBy: "\n").map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attrs)) }
        let widths = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
        let lh = CGFloat(px) * 1.15
        var cw = Int(ceil((widths.max() ?? 1) + CGFloat(px) * 0.5)), ch = Int(ceil(lh * CGFloat(lines.count) + CGFloat(px) * 0.3))
        cw = max(1, min(8192, cw)); ch = max(1, min(8192, ch))
        guard let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setShouldSmoothFonts(false)
        for (i, line) in lines.enumerated() {
            // Как textBaseline = 'middle' в canvas: середина строки на px·0.15 + lh·(i + 0.5) от верха
            let center = CGFloat(px) * 0.15 + lh * (CGFloat(i) + 0.5)
            let baselineFromTop = center + (font.ascender + font.descender) / 2
            ctx.textPosition = CGPoint(x: (CGFloat(cw) - widths[i]) / 2, y: CGFloat(ch) - baselineFromTop)
            CTLineDraw(line, ctx)
        }
        guard let data = ctx.data else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: cw, height: ch, mipmapped: false)
        td.usage = .shaderRead
        guard let t = gpu.device.makeTexture(descriptor: td) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0, withBytes: data, bytesPerRow: cw * 4)
        let e = TextTex(tex: Tex(t: t, w: cw, h: ch), key: key, w: CGFloat(cw) / (S * DPR), h: CGFloat(ch) / (S * DPR))
        texts[L.id] = e
        return e
    }

    // MARK: Цвета

    private static func hex(_ h: String?) -> SIMD4<Float> {
        var s = (h ?? "#ffffff").replacingOccurrences(of: "#", with: "")
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let n = Int(s.prefix(6), radix: 16) ?? 0xFFFFFF
        return SIMD4(Float((n >> 16) & 255) / 255, Float((n >> 8) & 255) / 255, Float(n & 255) / 255, 1)
    }
}
