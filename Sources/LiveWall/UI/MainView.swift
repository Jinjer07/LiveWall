import SwiftUI
import AppKit
import Combine

/// Корневой экран: заставка → условия → онбординг → приложение.
struct RootView: View {
    @EnvironmentObject var app: AppState
    enum Phase { case splash, tos, onboarding, main }
    @State private var phase: Phase = .splash

    @State private var windowVisible = true

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            // Когда окно закрыто, свёрнуто или полностью перекрыто — интерфейс выгружается,
            // чтобы анимации SwiftUI не тратили CPU и не будили WindowServer.
            if windowVisible { content.id(app.settings.language) }
        }
        .background(WindowVisibilityReader(visible: $windowVisible))
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            switch phase {
            case .splash:
                SplashView { advance(from: .splash) }
                    .transition(.opacity)
            case .tos:
                TOSView {
                    app.settings.tosAccepted = true
                    advance(from: .tos)
                }
                .transition(.opacity.combined(with: .scale(scale: 1.03)))
            case .onboarding:
                OnboardingView {
                    app.settings.onboardingDone = true
                    advance(from: .onboarding)
                }
                .transition(.opacity.combined(with: .scale(scale: 1.03)))
            case .main:
                MainView()
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }

            if let o = app.overlay {
                overlayView(o)
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: phase)
        .animation(.easeInOut(duration: 0.4), value: app.overlay)
        .preferredColorScheme(.dark)
        .tint(Theme.crimson)
        .onAppear {
            if !app.settings.showSplash { advance(from: .splash) }
        }
    }

    private func advance(from p: Phase) {
        switch p {
        case .splash:
            phase = !app.settings.tosAccepted ? .tos : (!app.settings.onboardingDone ? .onboarding : .main)
        case .tos:
            phase = app.settings.onboardingDone ? .main : .onboarding
        case .onboarding, .main:
            phase = .main
        }
    }

    @ViewBuilder
    private func overlayView(_ o: AppOverlay) -> some View {
        switch o {
        case .onboarding:
            OnboardingView { app.overlay = nil }
        case .credits:
            CreditsView { app.overlay = nil }
        case .tos:
            TOSView(onAccept: { app.overlay = nil }, showDecline: false)
        }
    }
}

/// Следит, видно ли окно (не закрыто, не свёрнуто, не перекрыто целиком).
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var visible: Bool

    final class Coordinator {
        var observers: [Any] = []
        weak var window: NSWindow?
        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { attach(v, context.coordinator) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if context.coordinator.window == nil { DispatchQueue.main.async { attach(nsView, context.coordinator) } }
    }

    private func attach(_ v: NSView, _ c: Coordinator) {
        guard let w = v.window, c.window !== w else { return }
        c.window = w
        let update = { [weak w] in
            guard let w else { return }
            let vis = w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
            if vis != visible { visible = vis }
        }
        let nc = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification] {
            c.observers.append(nc.addObserver(forName: name, object: w, queue: .main) { note in
                if note.name == NSWindow.willCloseNotification { visible = false } else { update() }
            })
        }
        update()
    }
}

struct MainView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 200)
            Rectangle().fill(Theme.stroke).frame(width: 1)
            ZStack {
                Theme.bg2
                VStack(spacing: 0) {
                    UpdateBanner()
                    content
                    .id(app.sidebar ?? .library)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)),
                                            removal: .identity))
                }
            }
            .animation(Theme.spring, value: app.sidebar)
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            if let t = app.toast {
                HStack(spacing: 10) {
                    Circle().fill(Theme.scarlet).frame(width: 7, height: 7).crimsonGlow(6)
                    Text(t).foregroundStyle(Theme.text)
                }
                .padding(.horizontal, 18).padding(.vertical, 11)
                .background(Capsule().fill(Theme.panelHi))
                .overlay(Capsule().stroke(Theme.crimson.opacity(0.5)))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: app.toast)
    }

    @ViewBuilder
    private var content: some View {
        switch app.sidebar ?? .library {
        case .library: LibraryView()
        case .gallery: GalleryView()
        case .playlists: PlaylistsView()
        case .workshop: WorkshopView()
        case .editor: SceneEditorView(model: app.sceneEditor)
        case .snow: SnowView()
        case .settings: SettingsView()
        }
    }
}

// MARK: - Сайдбар

struct Sidebar: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var engine: WallpaperEngine
    @Namespace private var ns

    var body: some View {
        ZStack {
            Theme.bg
            LinearGradient(colors: [Theme.crimson.opacity(0.10), .clear], startPoint: .top, endPoint: .center)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    LogoMark(size: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("LiveWall").font(.system(size: 15, weight: .heavy)).foregroundStyle(Theme.text)
                        Text(tr("живые обои")).font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 40)
                .padding(.bottom, 18)

                section(tr("ОБОИ"), [.library, .gallery, .playlists, .workshop])
                section(tr("СОЗДАНИЕ"), [.editor, .snow])
                section(tr("ПРИЛОЖЕНИЕ"), [.settings])

                Spacer()
                NowPlayingCard()
                    .padding(10)
            }
        }
    }

    private func section(_ title: String, _ items: [SidebarItem]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(Theme.text3)
                .padding(.horizontal, 20).padding(.bottom, 4)
            ForEach(items, id: \.self) { it in
                SidebarRow(item: it, selected: (app.sidebar ?? .library) == it, ns: ns, badge: badge(it)) {
                    withAnimation(Theme.spring) { app.sidebar = it }
                }
            }
        }
        .padding(.bottom, 12)
    }

    private func badge(_ it: SidebarItem) -> String? {
        switch it {
        case .library: return "\(library.items.count)"
        case .playlists: return app.playlists.isEmpty ? nil : "\(app.playlists.count)"
        default: return nil
        }
    }
}

private struct SidebarRow: View {
    let item: SidebarItem
    let selected: Bool
    let ns: Namespace.ID
    let badge: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20)
                    .foregroundStyle(selected ? .white : (hover ? Theme.scarlet : Theme.text2))
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .white : (hover ? Theme.text : Theme.text2))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge).font(.system(size: 10.5, weight: .bold)).monospacedDigit().lineLimit(1).fixedSize()
                        .foregroundStyle(selected ? .white : Theme.text3)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(selected ? Color.white.opacity(0.18) : Theme.panel))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.redGradient)
                        .matchedGeometryEffect(id: "sel", in: ns)
                        .shadow(color: Theme.crimson.opacity(0.55), radius: 12, y: 3)
                } else if hover {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel)
                }
            }
            .offset(x: hover && !selected ? 3 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .animation(Theme.snappy, value: hover)
        .onHover { hover = $0 }
    }
}

/// Мини-плеер внизу сайдбара: текущие обои, пауза, следующие, уровень звука.
struct NowPlayingCard: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var engine: WallpaperEngine

    var body: some View {
        let item = library.item(engine.primaryItemID)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if item != nil && !engine.userPaused { LiveDot() } else {
                    Circle().fill(Theme.text3).frame(width: 7, height: 7)
                }
                Text(item == nil ? tr("НЕТ ОБОЕВ") : (engine.userPaused ? tr("НА ПАУЗЕ") : tr("СЕЙЧАС")))
                    .font(.system(size: 10, weight: .bold)).tracking(2)
                    .foregroundStyle(engine.userPaused ? Theme.text3 : Theme.scarlet)
                Spacer()
                if app.settings.audioReactive { miniBars }
            }
            if let item {
                Thumbnail(item: item, version: library.thumbVersion)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
                Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            }
            HStack(spacing: 6) {
                Button { withAnimation(Theme.snappy) { engine.userPaused.toggle() } } label: {
                    Image(systemName: engine.userPaused ? "play.fill" : "pause.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 18)
                }
                .buttonStyle(CrimsonButtonStyle())
                .disabled(item == nil)
                if app.activePlaylist?.mode == .timer {
                    Button { app.nextInPlaylist() } label: { Image(systemName: "forward.fill") }
                        .buttonStyle(GhostButtonStyle(compact: true))
                }
                Spacer()
                Button { app.settings.muted.toggle() } label: {
                    Image(systemName: app.settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(IconButtonStyle())
                .help(tr("Звук обоев"))
            }
        }
        .panel(radius: 12, padding: 10)
    }

    /// Индикатор звука рисуется слоями Core Animation и не перерисовывает карточку SwiftUI.
    private var miniBars: some View {
        MiniAudioBars().frame(width: 16 * 4, height: 16)
    }
}

/// 16 полосок спектра на CALayer: обновляются напрямую из потока звука, без пересчёта интерфейса.
struct MiniAudioBars: NSViewRepresentable {
    func makeNSView(context: Context) -> BarsView { BarsView() }
    func updateNSView(_ nsView: BarsView, context: Context) {}

    final class BarsView: NSView {
        private var bars: [CALayer] = []
        private var sub: AnyCancellable?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for _ in 0..<16 {
                let l = CALayer()
                l.backgroundColor = NSColor(red: 1, green: 0.2, blue: 0.25, alpha: 1).cgColor
                l.cornerRadius = 1.25
                layer?.addSublayer(l)
                bars.append(l)
            }
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Подписка только пока индикатор на экране
            if window == nil { sub = nil; return }
            sub = AppState.shared.audioSubject
                .throttle(for: .milliseconds(80), scheduler: RunLoop.main, latest: true)
                .sink { [weak self] s in self?.show(s) }
            show([Float](repeating: 0, count: 128))
        }

        private func show(_ s: [Float]) {
            guard s.count >= 128 else { return }
            let h = bounds.height, step = bounds.width / 16
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.08)
            for i in 0..<16 {
                let v = CGFloat((s[i * 4] + s[64 + i * 4]) * 0.5)
                let bh = max(2, min(h, v * h))
                bars[i].frame = CGRect(x: CGFloat(i) * step, y: 0, width: 2.5, height: bh)
            }
            CATransaction.commit()
        }
    }
}
