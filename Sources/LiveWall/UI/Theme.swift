import SwiftUI

// MARK: - Палитра: угольный + алый

enum Theme {
    static let bg = Color(red: 0.043, green: 0.043, blue: 0.051)        // #0B0B0D
    static let bg2 = Color(red: 0.071, green: 0.071, blue: 0.082)       // #121215
    static let panel = Color(red: 0.094, green: 0.094, blue: 0.110)     // #18181C
    static let panelHi = Color(red: 0.129, green: 0.129, blue: 0.149)   // #212126
    static let stroke = Color.white.opacity(0.07)
    static let strokeHi = Color.white.opacity(0.14)

    static let crimson = Color(red: 0.863, green: 0.078, blue: 0.235)   // #DC143C
    static let scarlet = Color(red: 1.000, green: 0.200, blue: 0.250)   // #FF3340
    static let blood = Color(red: 0.520, green: 0.030, blue: 0.110)     // #85081C
    static let ember = Color(red: 1.000, green: 0.420, blue: 0.260)     // #FF6B42

    static let text = Color(red: 0.95, green: 0.95, blue: 0.96)
    static let text2 = Color(red: 0.62, green: 0.62, blue: 0.66)
    static let text3 = Color(red: 0.40, green: 0.40, blue: 0.44)

    static var redGradient: LinearGradient {
        LinearGradient(colors: [scarlet, crimson, blood], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var redHGradient: LinearGradient {
        LinearGradient(colors: [crimson, scarlet], startPoint: .leading, endPoint: .trailing)
    }
    static var panelGradient: LinearGradient {
        LinearGradient(colors: [panelHi, panel], startPoint: .top, endPoint: .bottom)
    }

    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.78)
}

// MARK: - Карточки и поверхности

struct PanelModifier: ViewModifier {
    var radius: CGFloat = 14
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.panelGradient)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.stroke, lineWidth: 1)
            )
    }
}

extension View {
    func panel(radius: CGFloat = 14, padding: CGFloat = 14) -> some View {
        modifier(PanelModifier(radius: radius, padding: padding))
    }

    /// Подъём и алое свечение при наведении.
    func hoverLift(scale: CGFloat = 1.025, glow: Bool = true) -> some View {
        modifier(HoverLift(scale: scale, glow: glow))
    }

    /// Появление с задержкой по индексу (каскад).
    func staggered(_ index: Int, base: Double = 0.03) -> some View {
        modifier(StaggerAppear(delay: Double(min(index, 24)) * base))
    }

    func crimsonGlow(_ radius: CGFloat = 18, opacity: Double = 0.55) -> some View {
        shadow(color: Theme.crimson.opacity(opacity), radius: radius)
    }
}

struct HoverLift: ViewModifier {
    let scale: CGFloat
    let glow: Bool
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hover ? scale : 1)
            .shadow(color: glow && hover ? Theme.crimson.opacity(0.35) : .clear, radius: hover ? 18 : 0, y: hover ? 6 : 0)
            .animation(Theme.snappy, value: hover)
            .onHover { hover = $0 }
    }
}

struct StaggerAppear: ViewModifier {
    let delay: Double
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .scaleEffect(shown ? 1 : 0.97)
            .onAppear {
                withAnimation(Theme.spring.delay(delay)) { shown = true }
            }
    }
}

// MARK: - Кнопки

struct CrimsonButtonStyle: ButtonStyle {
    var large = false
    func makeBody(configuration: Configuration) -> some View {
        CrimsonButtonBody(configuration: configuration, large: large)
    }
}

private struct CrimsonButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let large: Bool
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(.system(size: large ? 15 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 22 : 14)
            .padding(.vertical, large ? 11 : 7)
            .background(
                Capsule().fill(Theme.redGradient)
                    .overlay(Capsule().fill(Color.white.opacity(hover ? 0.10 : 0)))
            )
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
            .shadow(color: Theme.crimson.opacity(enabled ? (hover ? 0.7 : 0.4) : 0), radius: hover ? 16 : 10, y: 3)
            .scaleEffect(configuration.isPressed ? 0.96 : (hover ? 1.02 : 1))
            .opacity(enabled ? 1 : 0.4)
            .animation(Theme.snappy, value: hover)
            .animation(Theme.snappy, value: configuration.isPressed)
            .onHover { hover = $0 }
    }
}

struct GhostButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        GhostButtonBody(configuration: configuration, compact: compact)
    }
}

private struct GhostButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let compact: Bool
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(hover ? Theme.text : Theme.text2)
            .padding(.horizontal, compact ? 9 : 13)
            .padding(.vertical, compact ? 6 : 7)
            .background(Capsule().fill(hover ? Theme.panelHi : Theme.panel))
            .overlay(Capsule().stroke(hover ? Theme.crimson.opacity(0.6) : Theme.stroke, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(enabled ? 1 : 0.4)
            .animation(Theme.snappy, value: hover)
            .animation(Theme.snappy, value: configuration.isPressed)
            .onHover { hover = $0 }
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false
    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(hover ? Theme.scarlet : Theme.text2)
            .frame(width: 30, height: 30)
            .background(Circle().fill(hover ? Theme.panelHi : Color.clear))
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(Theme.snappy, value: hover)
            .onHover { hover = $0 }
    }
}

// MARK: - Заголовок страницы

struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    @State private var lineIn = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.text)
                HStack(spacing: 10) {
                    Capsule().fill(Theme.redHGradient)
                        .frame(width: lineIn ? 42 : 0, height: 3)
                        .crimsonGlow(6, opacity: 0.8)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.text2)
                    }
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 10)
        .onAppear { withAnimation(Theme.spring.delay(0.1)) { lineIn = true } }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = { EmptyView() }
    }
}

// MARK: - Поле поиска

struct SearchField: View {
    @Binding var text: String
    var prompt = tr("Поиск")
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(focused ? Theme.scarlet : Theme.text3)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.text)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Theme.text3)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Capsule().fill(Theme.panel))
        .overlay(Capsule().stroke(focused ? Theme.crimson.opacity(0.8) : Theme.stroke, lineWidth: 1))
        .shadow(color: focused ? Theme.crimson.opacity(0.35) : .clear, radius: 10)
        .animation(Theme.snappy, value: focused)
    }
}

// MARK: - Пульсирующая точка «LIVE»

struct LiveDot: View {
    /// Пульсация — бесконечная анимация; включаем только там, где точка одна.
    var animated = true
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle().fill(Theme.scarlet.opacity(0.5)).frame(width: 8, height: 8)
                .scaleEffect(pulse ? 2.4 : 1).opacity(pulse ? 0 : 1)
            Circle().fill(Theme.scarlet).frame(width: 7, height: 7)
        }
        .onAppear {
            guard animated else { return }
            withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

// MARK: - Логотип

struct LogoMark: View {
    var size: CGFloat = 64
    var progress: CGFloat = 1

    var body: some View {
        let w = size * 0.74, h = size * 0.54, r = size * 0.12, lw = max(1.5, size * 0.045)
        ZStack {
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .trim(from: 0, to: progress)
                .stroke(Theme.crimson.opacity(0.35), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                .frame(width: w, height: h)
                .offset(x: size * 0.12, y: -size * 0.12)
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .trim(from: 0, to: progress)
                .stroke(Theme.scarlet.opacity(0.65), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                .frame(width: w, height: h)
                .offset(x: size * 0.06, y: -size * 0.06)
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(Theme.redGradient)
                .frame(width: w, height: h)
                .overlay(
                    WaveGlyph()
                        .stroke(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: lw * 0.9, lineCap: .round, lineJoin: .round))
                        .frame(width: w * 0.62, height: h * 0.4)
                        .opacity(Double(progress))
                )
                .scaleEffect(0.6 + 0.4 * progress)
                .opacity(Double(min(1, progress * 1.6)))
                .crimsonGlow(size * 0.2, opacity: 0.6 * Double(progress))
        }
        .frame(width: size, height: size)
    }
}

/// Волна внутри логотипа.
struct WaveGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let steps = 40
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = rect.minX + rect.width * t
            let y = rect.midY + sin(t * .pi * 2.4) * rect.height * 0.42 * (0.4 + 0.6 * t)
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}

// MARK: - Угольки (частицы для фона)

struct EmberField: View {
    var count: Int = 70
    var intensity: Double = 1
    var speed: Double = 1

    private struct Ember {
        var x: Double, phase: Double, speed: Double, size: Double, wobble: Double, freq: Double, alpha: Double, hue: Int
    }

    @State private var embers: [Ember] = []

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate * speed
                let palette: [Color] = [Theme.crimson, Theme.scarlet, Theme.ember]
                ctx.blendMode = .plusLighter
                for e in embers {
                    let life = (t * e.speed + e.phase).truncatingRemainder(dividingBy: 1)
                    let y = size.height * (1.05 - life * 1.15)
                    let x = size.width * e.x + sin(t * e.freq + e.phase * 6.28) * e.wobble
                    let a = sin(life * .pi) * e.alpha * intensity
                    let r = e.size * 3
                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    let c = palette[e.hue % palette.count]
                    ctx.opacity = a
                    ctx.fill(Path(ellipseIn: rect),
                             with: .radialGradient(Gradient(colors: [c, c.opacity(0)]),
                                                   center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
                    ctx.fill(Path(ellipseIn: CGRect(x: x - e.size * 0.5, y: y - e.size * 0.5, width: e.size, height: e.size)),
                             with: .color(.white.opacity(0.8)))
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            if embers.isEmpty {
                embers = (0..<count).map { _ in
                    Ember(x: .random(in: 0...1), phase: .random(in: 0...1), speed: .random(in: 0.025...0.09),
                          size: .random(in: 1.2...3.4), wobble: .random(in: 6...30), freq: .random(in: 0.3...1.2),
                          alpha: .random(in: 0.35...0.95), hue: .random(in: 0...2))
                }
            }
        }
    }
}

/// Мягкое алое свечение для фонов.
struct CrimsonAura: View {
    var animated = true
    @State private var t = false
    var body: some View {
        ZStack {
            RadialGradient(colors: [Theme.crimson.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: 420)
                .scaleEffect(t ? 1.15 : 0.9)
                .offset(x: t ? 60 : -60, y: t ? -30 : 40)
            RadialGradient(colors: [Theme.blood.opacity(0.5), .clear], center: .center, startRadius: 0, endRadius: 360)
                .scaleEffect(t ? 0.9 : 1.2)
                .offset(x: t ? -120 : 100, y: t ? 80 : -60)
        }
        .blur(radius: 30)
        .allowsHitTesting(false)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) { t = true }
        }
    }
}

/// Чип-переключатель с плавающей подсветкой.
struct ChipBar<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let label: (Item) -> String
    var icon: ((Item) -> String?)? = nil
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { it in
                let selected = it == selection
                Button {
                    withAnimation(Theme.spring) { selection = it }
                } label: {
                    HStack(spacing: 5) {
                        if let name = icon?(it) { Image(systemName: name).font(.system(size: 11, weight: .semibold)) }
                        Text(label(it))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? .white : Theme.text2)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background {
                        if selected {
                            Capsule().fill(Theme.redGradient)
                                .matchedGeometryEffect(id: "chip", in: ns)
                                .crimsonGlow(8, opacity: 0.5)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Theme.panel))
        .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
    }
}

/// Тумблер в стиле темы.
struct CrimsonToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? AnyShapeStyle(Theme.redHGradient) : AnyShapeStyle(Theme.panelHi))
                    .frame(width: 38, height: 22)
                    .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                    .shadow(color: configuration.isOn ? Theme.crimson.opacity(0.5) : .clear, radius: 6)
                Circle().fill(.white).frame(width: 18, height: 18).padding(2)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            }
            .onTapGesture { withAnimation(Theme.snappy) { configuration.isOn.toggle() } }
        }
    }
}
