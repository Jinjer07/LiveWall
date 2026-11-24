import SwiftUI

// MARK: - Онбординг

struct OnboardingView: View {
    let onFinish: () -> Void
    @EnvironmentObject var app: AppState
    @State private var page = 0
    @State private var forward = true
    @Namespace private var ns

    private let pages: [(icon: String, kicker: String, title: String, text: String)] = [
        ("sparkles", tr("ДОБРО ПОЖАЛОВАТЬ"), tr("Рабочий стол, который живёт"),
         tr("LiveWall превращает обои в видео, интерактивные сцены, шейдеры и визуализаторы — прямо под иконками рабочего стола.")),
        ("square.grid.3x2.fill", tr("ЛЮБЫЕ ОБОИ"), tr("Шесть типов обоев"),
         tr("Видео, веб-страницы, картинки и слайдшоу, GLSL-шейдеры в стиле Shadertoy и сцены из слоёв. Просто перетащите файл в библиотеку.")),
        ("rectangle.stack.fill", tr("БИБЛИОТЕКА И STEAM"), tr("Ваша коллекция"),
         tr("Теги, избранное, поиск и плейлисты по таймеру или времени суток. Импорт видео- и веб-обоев из мастерской Wallpaper Engine.")),
        ("square.3.layers.3d", tr("РЕДАКТОР СЦЕН"), tr("Создавайте своё"),
         tr("Слои, параллакс от мыши, снег, искры и светлячки, волны и свечение, часы и дата. Перетаскивайте слои прямо в превью.")),
        ("waveform", tr("ЗВУК"), tr("Обои слышат музыку"),
         tr("Включите реакцию на звук — сцены, шейдеры и веб-обои будут пульсировать в такт тому, что играет на Mac.")),
        ("bolt.fill", tr("ПРОИЗВОДИТЕЛЬНОСТЬ"), tr("Умная пауза"),
         tr("Обои засыпают, когда приложение развёрнуто на весь экран, экран заблокирован или включена работа от батареи. FPS — под вашим контролем.")),
        ("checkmark.seal.fill", tr("ВСЁ ГОТОВО"), tr("Начнём?"),
         tr("Пара настроек напоследок — их всегда можно поменять в разделе «Настройки».")),
    ]

    var body: some View {
        ZStack {
            Theme.bg
            CrimsonAura()
            EmberField(count: 40, intensity: 0.55, speed: 0.7)

            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 10) {
                        LogoMark(size: 30)
                        Text("LiveWall").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                    }
                    Spacer()
                    if page < pages.count - 1 {
                        Button(tr("Пропустить")) { onFinish() }.buttonStyle(GhostButtonStyle(compact: true))
                    }
                }
                .padding(.horizontal, 32).padding(.top, 34)

                Spacer(minLength: 10)

                ZStack {
                    pageView(page)
                        .id(page)
                        .transition(.asymmetric(
                            insertion: .offset(x: forward ? 80 : -80).combined(with: .opacity).combined(with: .scale(scale: 0.96)),
                            removal: .offset(x: forward ? -80 : 80).combined(with: .opacity).combined(with: .scale(scale: 0.96))))
                }
                .frame(maxWidth: 980)

                Spacer(minLength: 10)

                HStack {
                    Button { go(page - 1) } label: { Label(tr("Назад"), systemImage: "chevron.left") }
                        .buttonStyle(GhostButtonStyle())
                        .opacity(page == 0 ? 0 : 1)
                        .disabled(page == 0)
                        .keyboardShortcut(.leftArrow, modifiers: [])

                    Spacer()
                    HStack(spacing: 8) {
                        ForEach(0..<pages.count, id: \.self) { i in
                            ZStack {
                                Capsule().fill(Theme.panelHi).frame(width: 8, height: 8)
                                if i == page {
                                    Capsule().fill(Theme.redHGradient)
                                        .frame(width: 28, height: 8)
                                        .matchedGeometryEffect(id: "dot", in: ns)
                                        .crimsonGlow(6, opacity: 0.8)
                                }
                            }
                            .frame(width: i == page ? 28 : 8, height: 8)
                            .onTapGesture { go(i) }
                        }
                    }
                    Spacer()

                    if page < pages.count - 1 {
                        Button { go(page + 1) } label: {
                            HStack(spacing: 6) { Text(tr("Далее")); Image(systemName: "chevron.right") }
                        }
                        .buttonStyle(CrimsonButtonStyle(large: true))
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    } else {
                        Button { onFinish() } label: {
                            HStack(spacing: 6) { Text(tr("Начать")); Image(systemName: "arrow.right") }
                        }
                        .buttonStyle(CrimsonButtonStyle(large: true))
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.horizontal, 32).padding(.bottom, 32)
            }
        }
    }

    private func go(_ p: Int) {
        guard p >= 0, p < pages.count, p != page else { return }
        forward = p > page
        withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { page = p }
    }

    @ViewBuilder
    private func pageView(_ i: Int) -> some View {
        let p = pages[i]
        HStack(spacing: 36) {
            illustration(i)
                .frame(width: 360, height: 320)
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: p.icon)
                    Text(p.kicker).tracking(3)
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.scarlet)
                .staggered(0, base: 0.08)

                Text(p.title)
                    .font(.system(size: 32, weight: .heavy))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .staggered(1, base: 0.08)

                Text(p.text)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .staggered(2, base: 0.08)

                if i == pages.count - 1 {
                    finalSettings.staggered(3, base: 0.08)
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private func illustration(_ i: Int) -> some View {
        switch i {
        case 0: WelcomeArt()
        case 1: TypesArt()
        case 2: LibraryArt()
        case 3: EditorArt()
        case 4: AudioArt()
        case 5: PerformanceArt()
        default: ReadyArt()
        }
    }

    private var finalSettings: some View {
        VStack(spacing: 12) {
            Toggle(tr("Запускать при входе в систему"), isOn: Binding(get: { app.settings.launchAtLogin }, set: { app.settings.launchAtLogin = $0 }))
            Toggle(tr("Реакция на звук"), isOn: Binding(get: { app.settings.audioReactive }, set: { app.settings.audioReactive = $0 }))
            Toggle(tr("Параллакс от мыши"), isOn: Binding(get: { app.settings.mouseInteraction }, set: { app.settings.mouseInteraction = $0 }))
            Toggle(tr("Пауза от батареи"), isOn: Binding(get: { app.settings.pauseOnBattery }, set: { app.settings.pauseOnBattery = $0 }))
        }
        .toggleStyle(CrimsonToggleStyle())
        .foregroundStyle(Theme.text)
        .panel(radius: 14, padding: 16)
    }
}

// MARK: - Иллюстрации страниц

private struct WelcomeArt: View {
    @State private var spin = false
    @State private var show: CGFloat = 0
    var body: some View {
        ZStack {
            Circle()
                .stroke(AngularGradient(colors: [Theme.crimson, .clear, Theme.scarlet, .clear, Theme.crimson], center: .center), lineWidth: 2)
                .frame(width: 300, height: 300)
                .rotationEffect(.degrees(spin ? 360 : 0))
            Circle()
                .stroke(AngularGradient(colors: [.clear, Theme.ember.opacity(0.7), .clear], center: .center), lineWidth: 1)
                .frame(width: 230, height: 230)
                .rotationEffect(.degrees(spin ? -360 : 0))
            Circle().fill(RadialGradient(colors: [Theme.crimson.opacity(0.45), .clear], center: .center, startRadius: 0, endRadius: 150))
                .frame(width: 300, height: 300)
            LogoMark(size: 150, progress: show)
        }
        .onAppear {
            withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) { spin = true }
            withAnimation(.easeInOut(duration: 1.2).delay(0.15)) { show = 1 }
        }
    }
}

private struct TypesArt: View {
    private let items: [(String, String)] = [("film", tr("Видео")), ("globe", tr("Веб")), ("photo", tr("Картинка")),
                                             ("photo.on.rectangle", tr("Слайдшоу")), ("sparkles", tr("Шейдер")), ("square.3.layers.3d", tr("Сцена"))]
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.9)) { tl in
            let active = Int(tl.date.timeIntervalSinceReferenceDate / 0.9) % items.count
            LazyVGrid(columns: [GridItem(.fixed(118)), GridItem(.fixed(118)), GridItem(.fixed(118))], spacing: 14) {
                ForEach(0..<items.count, id: \.self) { i in
                    let on = i == active
                    VStack(spacing: 10) {
                        Image(systemName: items[i].0).font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.text2))
                        Text(items[i].1).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(on ? Theme.text : Theme.text3)
                    }
                    .frame(width: 118, height: 118)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(on ? AnyShapeStyle(Theme.redGradient) : AnyShapeStyle(Theme.panelGradient))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(on ? Color.white.opacity(0.2) : Theme.stroke))
                    .scaleEffect(on ? 1.07 : 1)
                    .shadow(color: on ? Theme.crimson.opacity(0.6) : .clear, radius: 18)
                    .animation(Theme.spring, value: active)
                    .staggered(i, base: 0.06)
                }
            }
        }
    }
}

private struct LibraryArt: View {
    @State private var fan = false
    private let colors: [[Color]] = [[Theme.blood, Theme.crimson], [Theme.panelHi, Theme.crimson.opacity(0.7)], [Theme.crimson, Theme.ember]]
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let k = Double(i - 1)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: colors[i], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 230, height: 140)
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 5) {
                            Capsule().fill(.white.opacity(0.85)).frame(width: 90, height: 7)
                            Capsule().fill(.white.opacity(0.4)).frame(width: 56, height: 6)
                        }.padding(14)
                    }
                    .overlay(alignment: .topTrailing) {
                        if i == 2 {
                            HStack(spacing: 4) { LiveDot(); Text("LIVE").font(.system(size: 9, weight: .heavy)) }
                                .foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(.black.opacity(0.45))).padding(10)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.12)))
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                    .rotationEffect(.degrees(fan ? k * 12 : 0), anchor: .bottom)
                    .offset(x: fan ? k * 70 : 0, y: fan ? abs(k) * 18 : 0)
            }
            Image(systemName: "icloud.and.arrow.down.fill")
                .font(.system(size: 26)).foregroundStyle(.white)
                .padding(14).background(Circle().fill(Theme.redGradient)).crimsonGlow(14)
                .offset(x: 120, y: -110)
                .scaleEffect(fan ? 1 : 0.2).opacity(fan ? 1 : 0)
        }
        .onAppear { withAnimation(.spring(response: 0.8, dampingFraction: 0.65).delay(0.15)) { fan = true } }
    }
}

private struct EditorArt: View {
    @State private var tilt = CGPoint(x: 0.0, y: 0.0)
    @State private var spread = false
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let depth = CGFloat(i)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(layerFill(i))
                    .frame(width: 250, height: 160)
                    .overlay(layerContent(i))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(i == 2 ? Theme.scarlet.opacity(0.8) : Color.white.opacity(0.1), lineWidth: i == 2 ? 1.5 : 1))
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 6)
                    .offset(x: tilt.x * (depth + 1) * 14, y: (spread ? (1 - depth) * 46 : 0) + tilt.y * (depth + 1) * 10)
                    .rotation3DEffect(.degrees(52), axis: (x: 1, y: 0, z: 0.25), perspective: 0.6)
            }
        }
        .frame(width: 400, height: 340)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                withAnimation(.easeOut(duration: 0.25)) { tilt = CGPoint(x: (p.x - 200) / 200, y: (p.y - 170) / 170) }
            case .ended:
                withAnimation(Theme.spring) { tilt = .zero }
            }
        }
        .onAppear { withAnimation(.spring(response: 0.9, dampingFraction: 0.7).delay(0.15)) { spread = true } }
        .overlay(alignment: .bottom) {
            Text(tr("Поводите мышью — это параллакс")).font(.caption).foregroundStyle(Theme.text3)
        }
    }

    private func layerFill(_ i: Int) -> LinearGradient {
        switch i {
        case 0: return LinearGradient(colors: [Theme.blood, Theme.bg2], startPoint: .top, endPoint: .bottom)
        case 1: return LinearGradient(colors: [Theme.crimson.opacity(0.35), Theme.crimson.opacity(0.05)], startPoint: .top, endPoint: .bottom)
        default: return LinearGradient(colors: [Color.white.opacity(0.06), Color.white.opacity(0.02)], startPoint: .top, endPoint: .bottom)
        }
    }

    @ViewBuilder
    private func layerContent(_ i: Int) -> some View {
        switch i {
        case 0: Circle().fill(Theme.scarlet.opacity(0.8)).frame(width: 46).blur(radius: 2).offset(x: 50, y: -20)
        case 1: EmberField(count: 14, intensity: 1, speed: 1.2).clipShape(RoundedRectangle(cornerRadius: 14))
        default: Text("12:00").font(.system(size: 40, weight: .thin)).foregroundStyle(.white)
        }
    }
}

private struct AudioArt: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().fill(RadialGradient(colors: [Theme.crimson.opacity(0.25 + 0.15 * sin(t * 4)), .clear], center: .center, startRadius: 0, endRadius: 170))
                HStack(alignment: .center, spacing: 6) {
                    ForEach(0..<24, id: \.self) { i in
                        let x = Double(i)
                        let v = 0.25 + 0.75 * abs(sin(t * 2.6 + x * 0.45) * cos(t * 1.3 + x * 0.21))
                        let bass = i < 6 ? 0.25 * abs(sin(t * 5.2)) : 0
                        Capsule()
                            .fill(LinearGradient(colors: [Theme.ember, Theme.scarlet, Theme.crimson], startPoint: .top, endPoint: .bottom))
                            .frame(width: 8, height: CGFloat(40 + (v + bass) * 170))
                            .shadow(color: Theme.crimson.opacity(0.6), radius: 6)
                    }
                }
            }
        }
    }
}

private struct PerformanceArt: View {
    @State private var fill: CGFloat = 0
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.6)) { tl in
            let paused = Int(tl.date.timeIntervalSinceReferenceDate / 1.6) % 2 == 1
            gauge(paused)
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.4)) { fill = 0.78 } }
    }

    private func gauge(_ paused: Bool) -> some View {
        ZStack {
            Circle().stroke(Theme.panelHi, lineWidth: 14).frame(width: 220, height: 220)
            Circle().trim(from: 0, to: fill)
                .stroke(Theme.redHGradient, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 220, height: 220)
                .crimsonGlow(12)
            VStack(spacing: 4) {
                Image(systemName: paused ? "pause.fill" : "play.fill")
                    .font(.system(size: 40, weight: .bold)).foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                Text(paused ? tr("ПАУЗА") : "30 FPS").font(.system(size: 13, weight: .bold)).tracking(3).foregroundStyle(Theme.text2)
            }
            ForEach(0..<3, id: \.self) { i in
                let icons = ["arrow.up.left.and.arrow.down.right", "battery.25", "lock.fill"]
                let angle = Double(i) * 120 - 90
                Image(systemName: icons[i])
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.scarlet)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Theme.panel)).overlay(Circle().stroke(Theme.stroke))
                    .offset(x: cos(angle * .pi / 180) * 150, y: sin(angle * .pi / 180) * 150)
                    .staggered(i, base: 0.12)
            }
        }
        .animation(Theme.spring, value: paused)
    }
}

private struct ReadyArt: View {
    @State private var draw: CGFloat = 0
    @State private var burst = false
    var body: some View {
        ZStack {
            ForEach(0..<12, id: \.self) { i in
                Capsule().fill(Theme.redHGradient)
                    .frame(width: 4, height: 22)
                    .offset(y: burst ? -150 : -80)
                    .opacity(burst ? 0 : 1)
                    .rotationEffect(.degrees(Double(i) * 30))
            }
            Circle().fill(Theme.redGradient).frame(width: 170, height: 170)
                .crimsonGlow(30, opacity: 0.7)
                .scaleEffect(draw > 0 ? 1 : 0.5)
            CheckShape().trim(from: 0, to: draw)
                .stroke(.white, style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
                .frame(width: 80, height: 60)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.6).delay(0.1)) { draw = 1 }
            withAnimation(.easeOut(duration: 0.9).delay(0.3)) { burst = true }
        }
    }
}

private struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}
