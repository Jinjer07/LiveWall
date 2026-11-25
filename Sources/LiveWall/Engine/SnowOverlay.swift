import AppKit
import QuartzCore
import ImageIO

// MARK: - Настройки снега для рендера

struct SnowConfig: Equatable {
    var density = 0.5        // 0.1…1
    var size = 1.0           // 0.5…2
    var onWindows = true     // оседает на верхних краях окон
    var cursor = true        // курсор отталкивает и сметает снег
    var garlands = false     // гирлянды под строкой меню
    var lowPower = false     // экономный режим (меньше частиц и кадров)
}

// MARK: - Окна, на которых может лежать снег

struct SnowWindow {
    let id: Int
    let rect: CGRect         // в координатах экрана, начало сверху слева
}

enum SnowWindowScan {
    /// Обычные окна приложений (слой 0), спереди назад. Разрешения macOS не нужны: берутся только рамки.
    static func windows(on screenCG: CGRect) -> [SnowWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [SnowWindow] = []
        for info in list {
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            guard alpha > 0.5, owner != "Dock", owner != "Window Server",
                  let bd = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd),
                  r.width >= 160, r.height >= 80,
                  r.intersects(screenCG),
                  let num = (info[kCGWindowNumber as String] as? NSNumber)?.intValue else { continue }
            out.append(SnowWindow(id: num, rect: r.offsetBy(dx: -screenCG.minX, dy: -screenCG.minY)))
        }
        return out
    }
}

// MARK: - Холст со снегом

/// Прозрачный слой на весь экран: снежинки, сугробы на окнах, гирлянды.
/// Все координаты — в точках, начало сверху слева (view перевёрнут).
@MainActor
final class SnowCanvas: NSView {
    private struct Flake {
        var x: CGFloat, y: CGFloat
        var vx: CGFloat, vy: CGFloat
        var fall: CGFloat          // обычная скорость падения
        var r: CGFloat
        var phase: CGFloat
        var depth: CGFloat = 0.5   // 0 — далеко (мелкая, тусклая, медленная), 1 — близко (крупная, яркая)
        var flutter: CGFloat = 1   // частота покачивания
        var amp: CGFloat = 12      // размах покачивания
        var angle: CGFloat = 0     // поворот кристалла
        var spin: CGFloat = 0
        var life: CGFloat = .infinity   // у разлетевшихся от курсора — время жизни
    }

    private struct Surface {
        let id: Int
        let x0: CGFloat, x1: CGFloat   // видимый участок верхнего края
        let y: CGFloat
        let winX: CGFloat              // левый край окна (для индекса столбца)
        var landable = true            // false у сугроба закрытого окна: он только осыпается
    }

    /// Сугроб на верхнем краю окна. Когда окно двигают, снег съезжает в угол и сбрасывается с него.
    private struct Pile {
        var h: [CGFloat]
        var rect: CGRect
        var shed: Shed? = nil
        var ghost = false              // окно закрыто или свёрнуто: сугроб досыпается на старом месте
        var mass: CGFloat { h.reduce(0, +) }
    }

    private struct Shed {
        var dir: CGFloat               // −1 — сползает к левому углу, +1 — к правому
        var emit: CGFloat = 0          // таймер до следующего комка
        var t: CGFloat = 0             // сколько уже осыпается
    }

    private static let colW: CGFloat = 4
    private static let maxPile: CGFloat = 15

    var config = SnowConfig() { didSet { if config != oldValue { configChanged() } } }
    var menuBarHeight: CGFloat = 0
    var screenOrigin = CGPoint.zero    // Cocoa-координаты левого нижнего угла экрана
    var screenHeight: CGFloat = 0

    private var flakes: [Flake] = []
    private var surfaces: [Surface] = []
    private var piles: [Int: Pile] = [:]
    private var movingUntil: CFTimeInterval = 0
    private var ghostSeq = 0
    private var link: CADisplayLink?
    private var time: CGFloat = 0
    private var cursor: CGPoint?

    /// Пока окна двигаются, контроллер опрашивает их чаще, чтобы сугроб не отставал.
    var windowsAreMoving: Bool { CACurrentMediaTime() < movingUntil || piles.values.contains { $0.shed != nil } }

    // Вью НЕ перевёрнута: иначе AppKit сам переворачивает её слой, и вместе с нашим переводом
    // координат снег летел снизу вверх. y из координат симуляции (сверху слева) переводим в одном месте.
    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // Снег собран из слоёв Core Animation: каждая снежинка — слой с общей текстурой, сугробы —
    // векторные фигуры. Компонует их видеокарта, а процессор только двигает слои. Раньше каждый
    // кадр заново рисовался весь экран и картинка целиком отправлялась в систему — это стоило
    // около четверти процессора.
    private let flakeHost = CALayer()
    private let pileHost = CALayer()
    private let garlandLayer = CALayer()
    private var flakeLayers: [CALayer] = []
    private var pileLayers: [(fill: CAShapeLayer, edge: CAShapeLayer)] = []
    private var frameNo = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Обычные координаты Core Animation (начало снизу слева); симуляция считает сверху слева,
        // поэтому y переворачиваем сами — так картинки в слоях гарантированно не вверх ногами.
        let root = CALayer()
        layer = root                           // слой задаём до wantsLayer: вью «хостит» свой слой
        wantsLayer = true
        root.isGeometryFlipped = false
        for l in [garlandLayer, pileHost, flakeHost] {
            l.frame = CGRect(origin: .zero, size: frame.size)
            l.actions = ["sublayers": NSNull(), "contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            root.addSublayer(l)
        }
        garlandLayer.contentsGravity = .topLeft
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layer?.isGeometryFlipped = false
        for l in [pileHost, flakeHost] { l.frame = bounds }
    }

    private func renderFrame() {
        frameNo &+= 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateFlakeLayers()
        updatePileLayers()
        if config.garlands {
            if frameNo % 3 == 0 || garlandLayer.contents == nil { renderGarlands() }   // мерцание — 10 раз в секунду
        } else if garlandLayer.contents != nil {
            garlandLayer.contents = nil
        }
        CATransaction.commit()
        if frameNo == 240, let path = ProcessInfo.processInfo.environment["LW_SNOW_PNG"] { debugSnapshot(path) }
    }

    /// Отладка: кадр снега поверх тёмного фона в PNG (LW_SNOW_PNG=/путь/файл.png).
    private func debugSnapshot(_ path: String) {
        guard let root = layer else { return }
        let w = Int(bounds.width), h = Int(bounds.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 0.12, green: 0.14, blue: 0.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Рамки окон, чтобы было видно, где должны лежать сугробы (в координатах CG: снизу вверх)
        ctx.setStrokeColor(CGColor(red: 1, green: 0.3, blue: 0.3, alpha: 1)); ctx.setLineWidth(2)
        for (_, p) in piles where !p.ghost { ctx.stroke(CGRect(x: p.rect.minX, y: CGFloat(h) - p.rect.maxY, width: p.rect.width, height: p.rect.height)) }
        root.render(in: ctx)
        // Метка «верх», чтобы ориентация картинки была однозначной
        ctx.setFillColor(CGColor(red: 0.2, green: 1, blue: 0.3, alpha: 1)); ctx.fill(CGRect(x: 0, y: h - 12, width: 120, height: 12))
        if let img = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
        }
    }

    private func updateFlakeLayers() {
        let sprite = Self.softSprite
        while flakeLayers.count < flakes.count {
            let l = CALayer()
            l.contents = sprite
            l.contentsGravity = .resize
            l.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull(), "zPosition": NSNull(), "hidden": NSNull()]
            flakeHost.addSublayer(l)
            flakeLayers.append(l)
        }
        for (i, f) in flakes.enumerated() {
            let l = flakeLayers[i]
            let fade: CGFloat = f.life == .infinity ? 1 : min(1, f.life * 1.5)
            let d = f.r * 2.5 * (f.depth > 0.88 ? 1.6 : 1)      // самые близкие — крупные размытые «боке»
            l.isHidden = false
            l.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            l.position = CGPoint(x: f.x, y: bounds.height - f.y)
            l.opacity = Float((0.4 + f.depth * 0.55) * fade * (f.depth > 0.88 ? 0.55 : 1))
            l.zPosition = f.depth                               // далёкие под ближними, без сортировки
        }
        if flakeLayers.count > flakes.count {
            for l in flakeLayers[flakes.count...] where !l.isHidden { l.isHidden = true }
        }
    }

    private func updatePileLayers() {
        var shapes: [(CGPath, CGPath)] = []
        if config.onWindows {
            var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
            shapes = pileShapes().compactMap { f, e in
                guard let ff = f.copy(using: &flip), let ee = e.copy(using: &flip) else { return nil }
                return (ff, ee)
            }
        }
        while pileLayers.count < shapes.count {
            let fill = CAShapeLayer(), edge = CAShapeLayer()
            fill.fillColor = CGColor(red: 0.95, green: 0.97, blue: 1, alpha: 0.97)
            fill.shadowColor = CGColor(red: 0.55, green: 0.65, blue: 0.85, alpha: 1)
            fill.shadowOpacity = 0.35; fill.shadowRadius = 1.5; fill.shadowOffset = CGSize(width: 0, height: -1)
            edge.fillColor = nil
            edge.strokeColor = CGColor(gray: 1, alpha: 0.9)
            edge.lineWidth = 1.3; edge.lineJoin = .round; edge.lineCap = .round
            for l in [fill, edge] {
                l.actions = ["path": NSNull(), "hidden": NSNull()]
                pileHost.addSublayer(l)
            }
            pileLayers.append((fill, edge))
        }
        for (i, pair) in pileLayers.enumerated() {
            if i < shapes.count {
                // Фигуру пересчитываем каждый кадр, но отдаём слою, только если она изменилась:
                // неподвижный сугроб не перерисовывается
                if pair.fill.path != shapes[i].0 { pair.fill.path = shapes[i].0 }
                if pair.edge.path != shapes[i].1 { pair.edge.path = shapes[i].1 }
                pair.fill.isHidden = false; pair.edge.isHidden = false
            } else if !pair.fill.isHidden {
                pair.fill.isHidden = true; pair.edge.isHidden = true
                pair.fill.path = nil; pair.edge.path = nil
            }
        }
    }

    private func renderGarlands() {
        let w = Int(bounds.width.rounded()), h = Int(menuBarHeight + 48)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        drawGarlands(ctx)
        garlandLayer.frame = CGRect(x: 0, y: bounds.height - CGFloat(h), width: CGFloat(w), height: CGFloat(h))
        garlandLayer.contents = ctx.makeImage()
    }

    // MARK: Жизненный цикл

    func startLoop() {
        guard link == nil else { link?.isPaused = false; return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: config.lowPower ? 20 : 30)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func pauseLoop() { link?.isPaused = true }

    func stopLoop() { link?.invalidate(); link = nil }

    private func configChanged() {
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: config.lowPower ? 20 : 30)
        if !config.onWindows { piles.removeAll(); surfaces.removeAll() }
        renderFrame()
    }

    // MARK: Окна

    /// Вызывается несколько раз в секунду с актуальным списком окон (спереди назад).
    func updateWindows(_ wins: [SnowWindow]) {
        guard config.onWindows else { surfaces = []; return }
        var segs: [Surface] = []
        var alive = Set<Int>()
        for (i, w) in wins.enumerated() {
            let y = w.rect.minY
            guard y > menuBarHeight - 2, y < bounds.height - 40 else { continue }
            alive.insert(w.id)
            // Участки верхнего края, не закрытые окнами спереди
            var spans: [(CGFloat, CGFloat)] = [(w.rect.minX + 10, w.rect.maxX - 10)]
            for f in wins[..<i] where f.rect.minY < y + 1 && f.rect.maxY > y + 1 {
                spans = spans.flatMap { s -> [(CGFloat, CGFloat)] in
                    if f.rect.maxX <= s.0 || f.rect.minX >= s.1 { return [s] }
                    var r: [(CGFloat, CGFloat)] = []
                    if f.rect.minX > s.0 { r.append((s.0, f.rect.minX)) }
                    if f.rect.maxX < s.1 { r.append((f.rect.maxX, s.1)) }
                    return r
                }
            }
            for s in spans where s.1 - s.0 > 8 { segs.append(Surface(id: w.id, x0: s.0, x1: s.1, y: y, winX: w.rect.minX)) }

            let n = max(1, Int(w.rect.width / Self.colW))
            var p = piles[w.id] ?? Pile(h: [CGFloat](repeating: 0, count: n), rect: w.rect)
            let dx = w.rect.minX - p.rect.minX, dy = w.rect.minY - p.rect.minY, dw = w.rect.width - p.rect.width
            if abs(dx) > 1.5 || abs(dy) > 1.5 || abs(dw) > 1.5 {
                movingUntil = CACurrentMediaTime() + 0.45
                // Окно сдвинули: снег не едет вместе с ним, а остаётся в воздухе и осыпается вниз
                if p.mass > 0.6 { detach(p, towardRight: dx > 0 ? false : (dx < -1.5 ? true : massCenter(p.h) >= 0.5)) }
                p.h = [CGFloat](repeating: 0, count: n)
            }
            if p.h.count != n { p.h = (0..<n).map { $0 < p.h.count ? p.h[$0] : 0 } }
            p.rect = w.rect
            piles[w.id] = p
        }
        // Окно закрыто, свёрнуто или ушло на другой Space: сугроб осыпается на месте
        for (id, p) in piles where id > 0 && !alive.contains(id) {
            if p.mass > 0.6 { detach(p, towardRight: massCenter(p.h) >= 0.5) }
            piles[id] = nil
        }
        for (id, p) in piles where id < 0 {
            segs.append(Surface(id: id, x0: p.rect.minX + 10, x1: p.rect.maxX - 10, y: p.rect.minY, winX: p.rect.minX, landable: false))
        }
        surfaces = segs
    }

    /// Превращает сугроб в «призрак» на старом месте: он волной осыпается, начиная с угла.
    private func detach(_ p: Pile, towardRight: Bool) {
        ghostSeq -= 1
        var g = p
        g.ghost = true
        g.shed = Shed(dir: towardRight ? 1 : -1)
        piles[ghostSeq] = g
    }

    private func massCenter(_ h: [CGFloat]) -> CGFloat {
        let m = h.reduce(0, +)
        guard m > 0, h.count > 1 else { return 0.5 }
        var acc: CGFloat = 0
        for (i, v) in h.enumerated() { acc += v * CGFloat(i) }
        return acc / m / CGFloat(h.count - 1)
    }

    func clearSettledSnow() {
        for k in Array(piles.keys) {
            guard var p = piles[k] else { continue }
            p.h = [CGFloat](repeating: 0, count: p.h.count); p.shed = nil
            piles[k] = p
        }
    }

    // MARK: Симуляция

    @objc private func tick(_ link: CADisplayLink) {
        let dt = CGFloat(min(0.1, max(0.001, link.targetTimestamp - link.timestamp)))
        step(dt)
        renderFrame()
    }

    private var targetCount: Int {
        let area = bounds.width * bounds.height / (1440 * 900)
        let k = config.lowPower ? 0.5 : 1.0
        return Int(CGFloat(config.density * k) * 520 * max(0.5, area))
    }

    private func spawn(anywhere: Bool) -> Flake {
        // Три слоя глубины: больше мелких далёких снежинок, меньше крупных близких
        let u = CGFloat.random(in: 0...1)
        let depth = u < 0.5 ? CGFloat.random(in: 0...0.33) : (u < 0.85 ? CGFloat.random(in: 0.33...0.7) : CGFloat.random(in: 0.7...1))
        let s = CGFloat(config.size)
        let r = (0.9 + depth * 3.4) * s * CGFloat.random(in: 0.8...1.15)
        return Flake(x: .random(in: -20...max(1, bounds.width + 20)),
                     y: anywhere ? .random(in: 0...max(1, bounds.height)) : -10,
                     vx: 0, vy: 0,
                     fall: (22 + depth * 62) * CGFloat.random(in: 0.85...1.2),
                     r: r, phase: .random(in: 0...6.28), depth: depth,
                     flutter: CGFloat.random(in: 0.5...1.2),
                     amp: CGFloat.random(in: 2...8) * (1.1 - depth * 0.4),
                     angle: 0, spin: 0)
    }

    /// Плавный порывистый ветер: сумма медленных волн, чтобы снег то сносило, то успокаивало.
    private var wind: CGFloat {
        sin(time * 0.21) * 0.6 + sin(time * 0.57 + 1.3) * 0.3 + sin(time * 1.3 + 4.1) * 0.1
    }

    private func step(_ dt: CGFloat) {
        time += dt
        let target = targetCount
        while flakes.filter({ $0.life == .infinity }).count < target && flakes.count < target + 400 {
            var f = spawn(anywhere: flakes.isEmpty); f.vy = f.fall; flakes.append(f)
            if flakes.count > 4000 { break }
        }
        updateCursor()
        let R: CGFloat = 80
        var i = 0
        while i < flakes.count {
            var f = flakes[i]
            f.phase += dt
            f.angle += f.spin * dt
            let flutterX = sin(f.phase * f.flutter) * f.amp
            let target = flutterX + wind * 20 * (0.35 + f.depth)
            f.vx += (target - f.vx) * min(1, dt * 0.9)
            let bob = sin(f.phase * f.flutter * 1.7) * 2
            f.vy += (f.fall + bob - f.vy) * min(1, dt * 1.6)
            if f.life != .infinity {
                f.life -= dt
                if f.life <= 0 { flakes.remove(at: i); continue }
            }
            // Курсор отталкивает снежинки
            if config.cursor, let c = cursor {
                let dx = f.x - c.x, dy = f.y - c.y, d2 = dx * dx + dy * dy
                if d2 < R * R, d2 > 0.01 {
                    let d = sqrt(d2), push = (1 - d / R) * 520 * dt
                    f.vx += dx / d * push; f.vy += dy / d * push * 0.6
                }
            }
            let prevY = f.y
            f.x += f.vx * dt; f.y += f.vy * dt
            var landed = false
            if config.onWindows && (f.life == .infinity || f.vy > 0) {
                landed = land(&f, prevY: prevY)
            }
            if landed || f.y > bounds.height + 8 || f.x < -30 || f.x > bounds.width + 30 {
                if f.life != .infinity { flakes.remove(at: i); continue }
                f = spawn(anywhere: false); f.vy = f.fall
            }
            flakes[i] = f
            i += 1
        }
        if config.cursor, let c = cursor { sweep(around: c, radius: R, dt: dt) }
        shedPiles(dt)
        relaxPiles(dt)
    }

    /// Осыпание «призрака»: столбцы срываются волной от угла и падают вниз (не вместе с окном).
    private func shedPiles(_ dt: CGFloat) {
        for (id, var p) in piles where p.ghost {
            guard var sh = p.shed else { piles[id] = nil; continue }
            sh.t += dt
            let n = p.h.count
            // Волна бежит ~2400 пт/с: сугроб закрытого окна осыпается за полсекунды, а не висит
            // в воздухе белой полосой несколько секунд
            let reach = Int(sh.t * 2400 / Self.colW) + 2
            var any = false
            for k in 0..<n {
                let c = sh.dir < 0 ? k : n - 1 - k
                guard p.h[c] > 0.05 else { continue }
                any = true
                guard k <= reach else { continue }
                let x = p.rect.minX + (CGFloat(c) + 0.5) * Self.colW
                let cnt = min(6, max(1, Int(p.h[c] * 0.8)))
                for _ in 0..<cnt where flakes.count < 4500 {
                    flakes.append(Flake(x: x + .random(in: -2...2), y: p.rect.minY - .random(in: 0...p.h[c]),
                                        vx: sh.dir * .random(in: 0...40), vy: .random(in: -10...25), fall: 340,
                                        r: .random(in: 1.4...3.2) * CGFloat(config.size), phase: .random(in: 0...6.28),
                                        depth: 0.75, flutter: 1, amp: 1, life: .random(in: 2.0...3.4)))
                }
                p.h[c] = 0
            }
            if !any { piles[id] = nil } else { p.shed = sh; piles[id] = p }
        }
    }

    /// Сугроб оседает под собственным весом: крутые склоны выравниваются, получаются мягкие холмики.
    private func relaxPiles(_ dt: CGFloat) {
        let k = min(0.5, dt * 6)
        for (id, p0) in piles where p0.h.count > 2 && !p0.ghost {
            var h = p0.h
            var changed = false
            for c in 0..<(h.count - 1) {
                let d = h[c] - h[c + 1]
                if abs(d) > 1.1 {
                    let m = (abs(d) - 1.1) * 0.5 * k
                    if d > 0 { h[c] -= m; h[c + 1] += m } else { h[c] += m; h[c + 1] -= m }
                    changed = true
                }
            }
            if changed { piles[id]?.h = h }
        }
    }

    /// Снежинка пересекла поверхность сугроба — добавляем снег в столбец.
    private func land(_ f: inout Flake, prevY: CGFloat) -> Bool {
        guard CACurrentMediaTime() > movingUntil else { return false }
        for s in surfaces where s.landable && f.x >= s.x0 && f.x < s.x1 {
            guard var h = piles[s.id]?.h else { continue }
            let col = min(h.count - 1, max(0, Int((f.x - s.winX) / Self.colW)))
            let top = s.y - h[col]
            if prevY <= top && f.y >= top {
                let add = f.r * 2.0
                if h[col] < Self.maxPile * CGFloat(config.size.clamped(0.7, 1.6)) {
                    h[col] += add
                    if col > 0 { h[col - 1] += add * 0.55 }
                    if col + 1 < h.count { h[col + 1] += add * 0.55 }
                    piles[s.id]?.h = h
                } else if col > 1, col + 2 < h.count {
                    // Столбец полный — снег сползает на более низкого соседа
                    let side = h[col - 1] <= h[col + 1] ? col - 1 : col + 1
                    h[side] += add * 0.6
                    piles[s.id]?.h = h
                }
                return true
            }
        }
        return false
    }

    /// Курсор — как лопата: снег из-под него сдвигается влево и вправо и собирается горками по краям.
    private func sweep(around c: CGPoint, radius R: CGFloat, dt: CGFloat) {
        let zone: CGFloat = 30                 // полуширина «лопаты»
        for s in surfaces where s.landable {
            guard c.y > s.y - 70, c.y < s.y + 22, var h = piles[s.id]?.h else { continue }
            let lo = max(s.x0, c.x - zone - 40), hi = min(s.x1, c.x + zone + 40)
            guard lo < hi else { continue }
            let c0 = max(1, Int((lo - s.winX) / Self.colW)), c1 = min(h.count - 2, Int((hi - s.winX) / Self.colW))
            guard c0 <= c1 else { continue }
            let flow = min(0.7, dt * 14)
            var touched = false
            // Столбцы под курсором отдают снег наружу, на границе зоны он копится
            for col in c0...c1 where h[col] > 0.05 {
                let x = s.winX + (CGFloat(col) + 0.5) * Self.colW
                let d = x - c.x
                guard abs(d) < zone else { continue }
                let m = h[col] * flow
                h[col] -= m
                let t = d < 0 ? col - 1 : col + 1        // к ближайшему краю: влево или вправо
                h[t] += m * 0.9
                touched = true
                if m > 0.25, flakes.count < 4500, CGFloat.random(in: 0...1) < 0.25 {   // немного снежной пыли
                    flakes.append(Flake(x: x, y: s.y - h[col] - 1, vx: (d < 0 ? -1 : 1) * .random(in: 30...90), vy: .random(in: -70 ... -15),
                                        fall: 40, r: .random(in: 0.9...1.8) * CGFloat(config.size), phase: .random(in: 0...6.28),
                                        depth: 0.4, life: .random(in: 0.5...1.1)))
                }
            }
            if touched { piles[s.id]?.h = h }
        }
    }

    private func updateCursor() {
        let m = NSEvent.mouseLocation
        let x = m.x - screenOrigin.x, y = screenHeight - (m.y - screenOrigin.y)
        cursor = (x >= 0 && x <= bounds.width && y >= 0 && y <= bounds.height) ? CGPoint(x: x, y: y) : nil
    }

    // MARK: Рисование


    // Заранее нарисованные спрайты: мягкий диск (боке) и шестилучевой кристалл
    private static let softSprite: CGImage? = makeSprite(size: 64) { ctx, c in
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.85), CGColor(gray: 1, alpha: 0.28), CGColor(gray: 1, alpha: 0)] as CFArray,
            locations: [0, 0.3, 0.7, 1])!
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: 32, options: [])
    }

    private static func makeSprite(size: Int, _ draw: (CGContext, CGPoint) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(ctx, CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2))
        return ctx.makeImage()
    }

    /// Контуры сугробов: заливка и блик по гребню для каждого видимого участка края окна.
    private func pileShapes() -> [(CGPath, CGPath)] {
        var out: [(CGPath, CGPath)] = []
        for s in surfaces {
            guard let h = piles[s.id]?.h, !h.isEmpty else { continue }
            let c0 = max(0, Int((s.x0 - s.winX) / Self.colW)), c1 = min(h.count - 1, Int((s.x1 - s.winX) / Self.colW))
            guard c0 < c1, (h[c0...c1].max() ?? 0) > 0.8 else { continue }   // пустой край окна не рисуем: раньше он был белой линией
            let p = CGMutablePath(), edge = CGMutablePath()
            var drawingEdge = false
            p.move(to: CGPoint(x: s.winX + CGFloat(c0) * Self.colW, y: s.y + 0.5))
            for col in c0...c1 {
                // Сглаживание по пяти столбцам + неподвижная «рябь», чтобы край не был линейкой
                let a = h[max(0, col - 2)], b = h[max(0, col - 1)], m = h[col], d = h[min(h.count - 1, col + 1)], e = h[min(h.count - 1, col + 2)]
                let ripple = m > 0.6 ? sin(CGFloat(col) * 1.7 + CGFloat(abs(s.id) % 17)) * 0.35 : 0
                let xx = s.winX + (CGFloat(col) + 0.5) * Self.colW
                let toEnd = min(xx - s.x0 + 10, s.x1 - xx + 10)          // у краёв окна сугроб сходит на нет
                let taper = min(1, max(0.12, toEnd / 30))
                let y = s.y - (a + 2 * b + 3 * m + 2 * d + e) / 9 * (taper * taper * (3 - 2 * taper)) - ripple
                // Округление до полупикселя: дрожь в сотых долях не заставляет слой перерисовываться
                let pt = CGPoint(x: xx, y: (y * 2).rounded() / 2)
                p.addLine(to: pt)
                // Блик только там, где реально лежит снег
                if s.y - pt.y > 0.5 { if drawingEdge { edge.addLine(to: pt) } else { edge.move(to: pt); drawingEdge = true } } else { drawingEdge = false }
            }
            p.addLine(to: CGPoint(x: s.winX + CGFloat(c1) * Self.colW, y: s.y + 0.5))
            p.closeSubpath()
            // У осыпающегося сугроба (окно закрыто или сдвинуто) блика на гребне нет:
            // тонкая белая линия без окна под ней выглядела как артефакт
            out.append((p, s.landable ? edge : CGMutablePath()))
        }
        return out
    }

    private static let bulbColors: [CGColor] = [
        CGColor(red: 1.00, green: 0.25, blue: 0.25, alpha: 1), CGColor(red: 1.00, green: 0.72, blue: 0.20, alpha: 1),
        CGColor(red: 0.30, green: 0.90, blue: 0.45, alpha: 1), CGColor(red: 0.35, green: 0.70, blue: 1.00, alpha: 1),
        CGColor(red: 0.95, green: 0.45, blue: 0.95, alpha: 1)]

    /// Гирлянда провисающими дугами вдоль верхнего края экрана (под строкой меню).
    private func drawGarlands(_ ctx: CGContext) {
        let y0 = menuBarHeight + 1
        let span = max(160, bounds.width / CGFloat(max(3, Int(bounds.width / 260))))
        let n = Int((bounds.width / span).rounded(.up))
        ctx.setLineWidth(1.4)
        ctx.setStrokeColor(CGColor(red: 0.07, green: 0.2, blue: 0.1, alpha: 0.9))
        var idx = 0
        for k in 0..<n {
            let xa = CGFloat(k) * span, xb = min(bounds.width, xa + span)
            let sag: CGFloat = 26
            func pt(_ t: CGFloat) -> CGPoint {
                CGPoint(x: xa + (xb - xa) * t, y: y0 + sag * 4 * t * (1 - t))   // парабола
            }
            ctx.beginPath(); ctx.move(to: pt(0))
            for j in 1...24 { ctx.addLine(to: pt(CGFloat(j) / 24)) }
            ctx.strokePath()
            let bulbs = max(4, Int((xb - xa) / 24))
            for b in 0...bulbs {
                let p = pt(CGFloat(b) / CGFloat(bulbs))
                let tw = 0.6 + 0.4 * sin(time * 2.2 + CGFloat(idx) * 1.7)
                let col = Self.bulbColors[idx % Self.bulbColors.count]
                ctx.setFillColor(col.copy(alpha: 0.18 * tw) ?? col)
                ctx.fillEllipse(in: CGRect(x: p.x - 8, y: p.y - 4, width: 16, height: 16))
                ctx.setFillColor(col.copy(alpha: 0.55 + 0.45 * tw) ?? col)
                ctx.fillEllipse(in: CGRect(x: p.x - 3, y: p.y + 1, width: 6, height: 8))
                idx += 1
            }
        }
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(hi, Swift.max(lo, self)) }
}

// MARK: - Окно-оверлей одного экрана

@MainActor
final class SnowOverlay {
    let screenKey: String
    let window: NSWindow
    let canvas: SnowCanvas
    let cgBounds: CGRect

    init(info: WallpaperEngine.ScreenInfo, screen: NSScreen?) {
        screenKey = info.key
        cgBounds = info.cgBounds
        let w = NSWindow(contentRect: info.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true          // клики проходят насквозь
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        let c = SnowCanvas(frame: CGRect(origin: .zero, size: info.frame.size))
        c.autoresizingMask = [.width, .height]
        c.screenOrigin = info.frame.origin
        c.screenHeight = info.frame.height
        if let screen { c.menuBarHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY) }
        w.contentView = c
        window = w
        canvas = c
        w.setFrame(info.frame, display: false)
    }

    func show() { window.orderFrontRegardless(); canvas.startLoop() }
    func hide() { canvas.pauseLoop(); window.orderOut(nil) }
    func close() { canvas.stopLoop(); window.orderOut(nil); window.contentView = nil }
}

// MARK: - Контроллер

/// Управляет оверлеями: включение, пауза (отдельно от обоев), опрос окон.
@MainActor
final class SnowController {
    weak var app: AppState?
    private var overlays: [String: SnowOverlay] = [:]
    private var scanTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var paused: Set<String> = []

    private var enabled: Bool { app?.settings.snowEnabled ?? false }

    private var motionObserver: NSObjectProtocol?

    func start() {
        if motionObserver == nil {
            motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePause() }
            }
        }
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
            }
        }
        rebuild()
    }

    func shutdown() {
        pauseReason = nil
        scanTimer?.invalidate(); scanTimer = nil
        overlays.values.forEach { $0.close() }
        overlays = [:]
    }

    func settingsChanged() { rebuild() }

    func clearSnow() { overlays.values.forEach { $0.canvas.clearSettledSnow() } }

    private var config: SnowConfig {
        let s = app?.settings ?? AppSettings()
        return SnowConfig(density: s.snowDensity, size: s.snowSize, onWindows: s.snowOnWindows,
                          cursor: s.snowCursor, garlands: s.snowGarlands,
                          lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    private func rebuild() {
        guard enabled, let engine = app?.engine else { shutdown(); return }
        let infos = engine.screens
        // Убираем оверлеи пропавших экранов
        for (k, o) in overlays where !infos.contains(where: { $0.key == k }) { o.close(); overlays[k] = nil }
        for info in infos {
            let screen = NSScreen.screens.first { $0.frame == info.frame }
            if let o = overlays[info.key], o.window.frame == info.frame {
                o.canvas.config = config
                continue
            }
            overlays[info.key]?.close()
            let o = SnowOverlay(info: info, screen: screen)
            o.canvas.config = config
            overlays[info.key] = o
        }
        if scanTimer == nil { scheduleScan(after: 0.1) }
        updatePause()
    }

    /// 10 раз в секунду в покое и 30, пока окна двигаются или сугробы осыпаются: так сугроб не отстаёт от окна.
    private func scheduleScan(after delay: TimeInterval) {
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
    }

    /// Stage Manager наклоняет и уменьшает окна, а CGWindowList отдаёт для них обычную рамку.
    /// Сугроб рисовался бы в воздухе над окном, поэтому при включённом Stage Manager на окна снег не садится.
    static var stageManagerOn: Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
    }

    private func scan() {
        guard enabled else { return }
        var fast = false
        if config.onWindows {
            for (k, o) in overlays where !paused.contains(k) {
                o.canvas.updateWindows(Self.stageManagerOn ? [] : SnowWindowScan.windows(on: o.cgBounds))
                fast = fast || o.canvas.windowsAreMoving
            }
        }
        scheduleScan(after: fast ? 1.0 / 30 : 0.1)
    }

    /// Паузы снега не зависят от пауз обоев: у каждого свои переключатели в настройках.
    func updatePause() {
        guard let app, enabled else { pauseReason = nil; return }
        let s = app.settings, m = app.monitor
        // Раньше «Уменьшить движение» выключало снег всегда и молча — теперь только по настройке.
        var global: String?
        if s.snowPauseOnReduceMotion && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            global = tr("включено «Уменьшить движение» в Универсальном доступе")
        } else if s.snowPauseOnBattery && m.onBattery {
            global = tr("Mac работает от батареи")
        } else if s.snowPauseOnLock && (m.isLocked || m.isAsleep) {
            global = tr("экран заблокирован")
        }
        var now = Set<String>()
        var reason = global
        for (k, o) in overlays {
            var p = global != nil
            if !p && s.snowPauseOnFullscreen && m.fullscreenScreens.contains(k) { p = true; reason = reason ?? tr("открыто полноэкранное приложение") }
            if !p && s.snowPauseOnMaximized && m.maximizedScreens.contains(k) { p = true; reason = reason ?? tr("окно развёрнуто почти на весь экран") }
            if p { now.insert(k) }
            if p { o.hide() } else { o.show() }
        }
        if ProcessInfo.processInfo.environment["LW_DEBUG"] != nil, now != paused {
            NSLog("LW snow paused=%@ reason=%@ full=%@ max=%@", now.isEmpty ? "no" : "yes", reason ?? "-",
                  m.fullscreenScreens.joined(separator: ","), m.maximizedScreens.joined(separator: ","))
        }
        paused = now
        pauseReason = now.isEmpty ? nil : reason
        if pauseReason != oldReason { oldReason = pauseReason; app.objectWillChange.send() }
    }

    /// Почему снег сейчас не виден (для вкладки «Снег»); nil — снег идёт.
    private(set) var pauseReason: String?
    private var oldReason: String?
}
