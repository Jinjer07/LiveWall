import SwiftUI
import AppKit
import QuartzCore

// MARK: - Новогоднее оформление
//
// Цвета леденца (алый и белый), гирлянды с мерцающими лампочками и леденцы-украшения.
// Мерцание гирлянд — анимации Core Animation: они выполняются системным рендер-сервером,
// и интерфейс SwiftUI ради них не перерисовывается.

// MARK: Полоски леденца

/// Диагональные полоски, как на рождественском леденце.
struct CandyStripes: View {
    var stripe: CGFloat = 7
    var color: Color = .white
    var angle: Angle = .degrees(-35)

    var body: some View {
        Canvas { ctx, size in
            let d = (size.width * size.width + size.height * size.height).squareRoot()
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.rotate(by: angle)
            var x = -d
            while x < d {
                ctx.fill(Path(CGRect(x: x, y: -d, width: stripe, height: d * 2)), with: .color(color))
                x += stripe * 2
            }
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// Полоски леденца поверх фона (только в новогоднем оформлении).
    @ViewBuilder
    func candyOverlay<S: Shape>(_ shape: S, opacity: Double = 0.2, stripe: CGFloat = 7) -> some View {
        if Theme.festive {
            overlay(CandyStripes(stripe: stripe, color: .white.opacity(opacity)).clipShape(shape))
        } else {
            self
        }
    }
}

// MARK: Леденец-трость

/// Рождественский леденец: белая трость с алыми полосками.
struct CandyCane: View {
    var lineWidth: CGFloat = 6

    var body: some View {
        Canvas { ctx, size in
            let lw = lineWidth
            let r = size.width / 2 - lw / 2 - 1                    // радиус крючка
            let cx = size.width / 2, cy = r + lw / 2 + 1
            var p = Path()
            p.move(to: CGPoint(x: cx + r, y: size.height - lw / 2))     // низ трости
            p.addLine(to: CGPoint(x: cx + r, y: cy))
            p.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .degrees(0), endAngle: .degrees(-180), clockwise: true)
            p.addLine(to: CGPoint(x: cx - r, y: cy + r * 0.55))
            // Тень, белая основа, алые полоски поперёк и блик
            ctx.stroke(p, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: lw + 2, lineCap: .round, lineJoin: .round))
            ctx.stroke(p, with: .color(.white), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
            ctx.stroke(p, with: .color(Theme.candyRed), style: StrokeStyle(lineWidth: lw, lineCap: .butt, lineJoin: .round, dash: [lw * 0.75, lw * 0.75]))
            ctx.stroke(p, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: lw * 0.25, lineCap: .round))
        }
        .allowsHitTesting(false)
    }
}

/// Два перекрещённых леденца с веточкой остролиста — украшение у логотипа.
struct CandyCaneOrnament: View {
    var body: some View {
        ZStack {
            CandyCane(lineWidth: 4.5).frame(width: 15, height: 34).rotationEffect(.degrees(-16)).offset(x: -5)
            CandyCane(lineWidth: 4.5).frame(width: 15, height: 34).scaleEffect(x: -1, y: 1).rotationEffect(.degrees(16)).offset(x: 5)
            Holly().frame(width: 20, height: 12).offset(y: 6)
        }
        .frame(width: 34, height: 36)
        .allowsHitTesting(false)
    }
}

/// Два листика остролиста и ягоды.
struct Holly: View {
    var body: some View {
        Canvas { ctx, size in
            let green = Color(red: 0.12, green: 0.55, blue: 0.27)
            for (dx, rot) in [(-size.width * 0.22, -25.0), (size.width * 0.22, 25.0)] {
                var c = ctx
                c.translateBy(x: size.width / 2 + dx, y: size.height / 2)
                c.rotate(by: .degrees(rot))
                c.fill(Path(ellipseIn: CGRect(x: -size.width * 0.24, y: -size.height * 0.2, width: size.width * 0.48, height: size.height * 0.4)), with: .color(green))
            }
            for (dx, dy) in [(-2.2, -1.0), (2.2, -1.0), (0.0, 1.6)] {
                let p = CGPoint(x: size.width / 2 + dx, y: size.height / 2 + dy)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(Theme.candyRed))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: Гирлянда

/// Провисающая гирлянда с мерцающими красными и белыми лампочками.
struct Garland: View {
    var sag: CGFloat = 12
    var body: some View {
        GarlandRepresentable(sag: sag).allowsHitTesting(false)
    }
}

private struct GarlandRepresentable: NSViewRepresentable {
    let sag: CGFloat
    func makeNSView(context: Context) -> GarlandNSView { GarlandNSView(sag: sag) }
    func updateNSView(_ v: GarlandNSView, context: Context) {}
}

final class GarlandNSView: NSView {
    private let sag: CGFloat
    private var builtWidth: CGFloat = -1

    init(sag: CGFloat) {
        self.sag = sag
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError() }

    // Координаты сверху вниз — так проще вешать лампочки под провод
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        if abs(bounds.width - builtWidth) > 0.5 { rebuild() }
    }

    private static let red = NSColor(red: 1.0, green: 0.16, blue: 0.24, alpha: 1)
    private static let white = NSColor(red: 1.0, green: 0.97, blue: 0.95, alpha: 1)
    private static let wire = NSColor(red: 0.08, green: 0.30, blue: 0.16, alpha: 0.95)

    private func rebuild() {
        builtWidth = bounds.width
        guard let root = layer, bounds.width > 20 else { return }
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let w = bounds.width, top: CGFloat = 3
        let spans = max(2, Int((w / 170).rounded()))
        let span = w / CGFloat(spans)
        // Точка на провисающей дуге: парабола между крючками
        func pt(_ x: CGFloat) -> CGPoint {
            let t = (x.truncatingRemainder(dividingBy: span)) / span
            return CGPoint(x: x, y: top + sag * 4 * t * (1 - t))
        }

        let wirePath = CGMutablePath()
        wirePath.move(to: pt(0))
        var x: CGFloat = 0
        while x < w { x = min(w, x + 3); wirePath.addLine(to: x == w ? CGPoint(x: w, y: top) : pt(x)) }
        let wireLayer = CAShapeLayer()
        wireLayer.path = wirePath
        wireLayer.strokeColor = Self.wire.cgColor
        wireLayer.fillColor = nil
        wireLayer.lineWidth = 1.6
        wireLayer.lineCap = .round
        root.addSublayer(wireLayer)

        // Лампочки: красная и белая по очереди, каждая мерцает в своём ритме
        let step: CGFloat = 26
        var i = 0
        var bx = step / 2
        while bx < w - 4 {
            let p = pt(bx)
            let color = i % 2 == 0 ? Self.red : Self.white
            let socket = CALayer()
            socket.frame = CGRect(x: p.x - 2.5, y: p.y - 1, width: 5, height: 4)
            socket.backgroundColor = Self.wire.cgColor
            socket.cornerRadius = 1
            root.addSublayer(socket)

            let bulb = CALayer()
            bulb.frame = CGRect(x: p.x - 3.5, y: p.y + 2, width: 7, height: 10)
            bulb.cornerRadius = 3.5
            bulb.backgroundColor = color.cgColor
            bulb.shadowColor = color.cgColor
            bulb.shadowOffset = .zero
            bulb.shadowRadius = 6
            bulb.shadowOpacity = 0.9
            bulb.shadowPath = CGPath(roundedRect: bulb.bounds, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
            root.addSublayer(bulb)

            let dur = Double.random(in: 0.9...1.8)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0; fade.toValue = 0.35
            let glow = CABasicAnimation(keyPath: "shadowOpacity")
            glow.fromValue = 0.95; glow.toValue = 0.1
            let g = CAAnimationGroup()
            g.animations = [fade, glow]
            g.duration = dur
            g.autoreverses = true
            g.repeatCount = .infinity
            g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            g.beginTime = CACurrentMediaTime() + Double.random(in: 0...dur * 2)
            g.fillMode = .backwards
            g.isRemovedOnCompletion = false
            bulb.add(g, forKey: "twinkle")

            i += 1
            bx += step
        }
        CATransaction.commit()
    }
}
