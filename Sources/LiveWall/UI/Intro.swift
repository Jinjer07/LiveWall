import SwiftUI
import AppKit

// MARK: - Заставка при запуске

struct SplashView: View {
    let onFinish: () -> Void

    @State private var logo: CGFloat = 0
    @State private var glow = false
    @State private var letters = 0
    @State private var subtitle = false
    @State private var line: CGFloat = 0
    @State private var exiting = false
    @State private var finished = false

    private let word = Array("LIVEWALL")

    var body: some View {
        ZStack {
            Theme.bg
            RadialGradient(colors: [Theme.crimson.opacity(glow ? 0.45 : 0), .clear],
                           center: .center, startRadius: 0, endRadius: glow ? 520 : 120)
            EmberField(count: 90, intensity: glow ? 1 : 0, speed: 1.4)
                .opacity(exiting ? 0 : 1)

            VStack(spacing: 26) {
                LogoMark(size: 132, progress: logo)
                    .rotation3DEffect(.degrees(Double(1 - logo) * 40), axis: (x: 1, y: -0.4, z: 0))

                HStack(spacing: 6) {
                    ForEach(0..<word.count, id: \.self) { i in
                        Text(String(word[i]))
                            .font(.system(size: 46, weight: .heavy, design: .default))
                            .foregroundStyle(i < 4 ? AnyShapeStyle(Theme.text) : AnyShapeStyle(Theme.redHGradient))
                            .opacity(i < letters ? 1 : 0)
                            .offset(y: i < letters ? 0 : 22)
                            .blur(radius: i < letters ? 0 : 8)
                            .scaleEffect(i < letters ? 1 : 1.4)
                    }
                }
                .tracking(4)

                VStack(spacing: 10) {
                    Capsule().fill(Theme.redHGradient)
                        .frame(width: 260 * line, height: 2)
                        .crimsonGlow(8, opacity: 0.9)
                    Text(tr("ЖИВЫЕ ОБОИ ДЛЯ MAC"))
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(6)
                        .foregroundStyle(Theme.text2)
                        .opacity(subtitle ? 1 : 0)
                        .offset(y: subtitle ? 0 : 8)
                }
            }
            .scaleEffect(exiting ? 1.12 : 1)
            .blur(radius: exiting ? 18 : 0)
            .opacity(exiting ? 0 : 1)

            VStack {
                Spacer()
                Text(tr("Нажмите любую клавишу или кликните, чтобы пропустить"))
                    .font(.caption).foregroundStyle(Theme.text3)
                    .opacity(subtitle && !exiting ? 1 : 0)
                    .padding(.bottom, 26)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .background(KeyCatcher { finish() })
        .task { await run() }
    }

    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    private func run() async {
        withAnimation(.easeOut(duration: 1.2)) { glow = true }
        withAnimation(.easeInOut(duration: 1.1)) { logo = 1 }
        await sleep(0.55)
        for i in 1...word.count {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { letters = i }
            await sleep(0.06)
        }
        withAnimation(.easeOut(duration: 0.7)) { line = 1 }
        await sleep(0.25)
        withAnimation(.easeOut(duration: 0.6)) { subtitle = true }
        await sleep(1.4)
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        withAnimation(.easeIn(duration: 0.5)) { exiting = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { onFinish() }
    }
}

/// Перехватывает нажатие любой клавиши (для пропуска заставки).
struct KeyCatcher: NSViewRepresentable {
    let action: () -> Void
    final class V: NSView {
        var action: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }
        override func keyDown(with event: NSEvent) { action?() }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.action = action; return v }
    func updateNSView(_ v: V, context: Context) { v.action = action }
}

// MARK: - Условия использования

struct TOSView: View {
    let onAccept: () -> Void
    var showDecline = true
    @State private var agreed = false
    @State private var reachedEnd = false
    @State private var appear = false

    private let sections: [(String, String)] = [
        (tr("1. Что такое LiveWall"),
         tr("LiveWall — приложение для macOS, которое показывает живые обои: видео, веб-страницы, GLSL-шейдеры, сцены и слайдшоу. Это личный некоммерческий проект, созданный для вашего компьютера.")),
        (tr("2. Лицензия"),
         tr("Вам предоставляется право бесплатно использовать, изменять и пересобирать LiveWall для личных целей. Исходный код принадлежит вам.")),
        (tr("3. Чужой контент"),
         tr("Обои, которые вы импортируете (видео, изображения, проекты из мастерской Wallpaper Engine), принадлежат их авторам. Используйте только контент, на который у вас есть права. Для обоев из мастерской Steam требуется купленная копия Wallpaper Engine; LiveWall не обходит никаких защит и не распространяет чужой контент.")),
        (tr("4. Steam и steamcmd"),
         tr("Загрузка из мастерской выполняется официальной утилитой Valve steamcmd. Вход в Steam вы выполняете сами в Терминале — LiveWall не видит, не хранит и не передаёт ваш пароль или коды Steam Guard. Steam и steamcmd — товарные знаки Valve Corporation.")),
        (tr("5. Конфиденциальность"),
         tr("LiveWall не собирает персональные данные. Разрешение «Запись экрана и системного звука» используется только для получения спектра звука; изображение экрана не записывается и не сохраняется. Приложение обращается к GitHub (галерея и проверка обновлений) и, если вы указали город, к Open-Meteo (погода) — туда уходят только название города и координаты. Все настройки и библиотека хранятся локально в ~/Library/Application Support/LiveWall.")),
        (tr("6. Ресурсы и энергопотребление"),
         tr("Живые обои расходуют ресурсы процессора, видеокарты и батареи. Приложение умеет ставить обои на паузу, но вы сами отвечаете за выбор настроек производительности.")),
        (tr("7. Отказ от гарантий"),
         tr("Программа предоставляется «как есть», без каких-либо гарантий. Авторы не несут ответственности за возможные сбои, потерю данных или иной ущерб, связанный с использованием программы.")),
        (tr("8. Изменения"),
         tr("Условия могут обновляться вместе с приложением. Продолжая использовать LiveWall после обновления, вы соглашаетесь с новой редакцией.")),
    ]

    var body: some View {
        ZStack {
            Theme.bg
            CrimsonAura()
            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    LogoMark(size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tr("Условия использования")).font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.text)
                        Text(tr("Пожалуйста, прочитайте до конца перед началом работы"))
                            .font(.system(size: 13)).foregroundStyle(Theme.text2)
                    }
                    Spacer()
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(sections.enumerated()), id: \.offset) { i, s in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(s.0).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.scarlet)
                                Text(s.1).font(.system(size: 13)).foregroundStyle(Theme.text2)
                                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                            }
                            .staggered(i, base: 0.05)
                        }
                        Text(tr("Редакция от 24 ноября 2026 г.")).font(.caption).foregroundStyle(Theme.text3)
                            .onAppear { withAnimation(Theme.spring) { reachedEnd = true } }
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .panel(radius: 16, padding: 0)

                HStack(spacing: 14) {
                    Toggle(isOn: $agreed) {
                        Text(reachedEnd ? tr("Я прочитал(а) и принимаю условия") : tr("Прокрутите условия до конца"))
                            .foregroundStyle(reachedEnd ? Theme.text : Theme.text3)
                    }
                    .toggleStyle(CrimsonToggleStyle())
                    .disabled(!reachedEnd)
                    .frame(maxWidth: 360)
                    Spacer()
                    if showDecline {
                        Button(tr("Отклонить и выйти")) { NSApp.terminate(nil) }.buttonStyle(GhostButtonStyle())
                    }
                    Button { onAccept() } label: { Label(tr("Принять"), systemImage: "checkmark.seal.fill") }
                        .buttonStyle(CrimsonButtonStyle(large: true))
                        .disabled(!agreed)
                }
            }
            .padding(36)
            .frame(maxWidth: 860)
            .opacity(appear ? 1 : 0)
            .offset(y: appear ? 0 : 24)
        }
        .onAppear { withAnimation(Theme.spring) { appear = true } }
    }
}

// MARK: - Титры

struct CreditsView: View {
    let onClose: () -> Void
    @State private var offset: CGFloat = 0
    @State private var contentHeight: CGFloat = 1
    @State private var started = false

    private let blocks: [(String, [String])] = [
        (tr("В главной роли"), ["LiveWall"]),
        (tr("Идея и продюсирование"), ["Nijat Afandiyev"]),
        (tr("Движок рабочего стола"), [tr("AppKit · NSWindow на уровне рабочего стола")]),
        (tr("Рендеринг"), ["WebKit · WebGL 2", "AVFoundation", "Core Animation"]),
        (tr("Звук"), ["ScreenCaptureKit", "Accelerate · vDSP FFT"]),
        (tr("Интерфейс"), ["SwiftUI"]),
        (tr("Совместимость"), [tr("API веб-обоев Wallpaper Engine"), tr("Шейдеры в стиле Shadertoy")]),
        (tr("Мастерская"), ["steamcmd · Valve Corporation"]),
        (tr("Вдохновение"), ["Wallpaper Engine", tr("и все, кто делает рабочий стол живым")]),
        (tr("Цветовая гамма"), [tr("Угольный · Алый")]),
        (tr("Особая благодарность"), [tr("Вам — за то, что досмотрели титры")]),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.bg
                CrimsonAura()
                EmberField(count: 60, intensity: 0.8, speed: 0.8)

                VStack(spacing: 44) {
                    VStack(spacing: 16) {
                        LogoMark(size: 110)
                        Text("LIVEWALL").font(.system(size: 40, weight: .heavy)).tracking(8).foregroundStyle(Theme.text)
                        Text(tr("версия %@", RemoteConfig.appVersion)).font(.system(size: 13, weight: .medium)).tracking(3).foregroundStyle(Theme.text3)
                    }
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                        VStack(spacing: 8) {
                            Text(b.0.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(4).foregroundStyle(Theme.scarlet)
                            ForEach(b.1, id: \.self) { n in
                                Text(n).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                            }
                        }
                    }
                    VStack(spacing: 10) {
                        Capsule().fill(Theme.redHGradient).frame(width: 120, height: 2).crimsonGlow(8)
                        Text(tr("Сделано с любовью к красивым рабочим столам")).font(.system(size: 14)).foregroundStyle(Theme.text2)
                        Text("© 2026").font(.caption).foregroundStyle(Theme.text3)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(width: min(640, geo.size.width - 80))
                .background(GeometryReader { g in Color.clear.onAppear { contentHeight = g.size.height } })
                .offset(y: offset)
                .mask(
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.15),
                                           .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                )

                VStack {
                    HStack {
                        Spacer()
                        Button { onClose() } label: { Label(tr("Закрыть"), systemImage: "xmark") }
                            .buttonStyle(GhostButtonStyle())
                            .keyboardShortcut(.cancelAction)
                    }
                    Spacer()
                    HStack {
                        Button { restart(geo.size.height) } label: { Label(tr("Сначала"), systemImage: "arrow.counterclockwise") }
                            .buttonStyle(GhostButtonStyle(compact: true))
                        Spacer()
                    }
                }
                .padding(24)
            }
            .onAppear { restart(geo.size.height) }
        }
    }

    private func restart(_ h: CGFloat) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { offset = h * 0.5 + contentHeight * 0.5 + 40 }
            let distance = h + contentHeight + 80
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.linear(duration: Double(distance) / 110)) {   // 110 pt/с
                    offset = -(h * 0.5 + contentHeight * 0.5 + 40)
                }
            }
        }
    }
}
