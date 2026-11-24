import SwiftUI

// MARK: - Галерея

struct GalleryView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var library: LibraryStore
    @ObservedObject var gallery = AppState.shared.gallery

    enum Filter: Hashable { case all, scenes, shaders }
    @State private var filter: Filter = .all

    private var items: [GalleryItem] {
        gallery.items.filter {
            switch filter {
            case .all: return true
            case .scenes: return $0.type == "scene"
            case .shaders: return $0.type == "shader"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: tr("Галерея"), subtitle: tr("Готовые сцены и шейдеры — установка в один клик")) {
                Button { gallery.load() } label: { Label(tr("Обновить"), systemImage: "arrow.clockwise") }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(gallery.loading)
            }
            HStack {
                ChipBar(items: [Filter.all, .scenes, .shaders], selection: $filter, label: { f in
                    switch f {
                    case .all: return tr("Все")
                    case .scenes: return tr("Сцены")
                    case .shaders: return tr("Шейдеры")
                    }
                }, icon: { f in
                    switch f {
                    case .all: return nil
                    case .scenes: return "square.3.layers.3d"
                    case .shaders: return "sparkles"
                    }
                })
                Spacer()
            }
            .padding(.horizontal, 20).padding(.bottom, 10)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14)], spacing: 16) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                        GalleryCard(item: it, preview: gallery.previews[it.id],
                                    installed: gallery.installed(it) != nil,
                                    busy: gallery.installing.contains(it.id)) { apply in
                            gallery.install(it, apply: apply)
                        }
                        .staggered(i, base: 0.03)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
            .overlay {
                if gallery.loading && gallery.items.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large).tint(Theme.crimson)
                        Text(tr("Загружаем каталог…")).foregroundStyle(Theme.text2)
                    }
                } else if let e = gallery.error, gallery.items.isEmpty {
                    VStack(spacing: 14) {
                        EmptyState(icon: "wifi.exclamationmark", title: tr("Нет соединения"), text: e)
                        Button(tr("Повторить")) { gallery.load() }.buttonStyle(CrimsonButtonStyle())
                    }
                }
            }
        }
        .onAppear { gallery.loadIfNeeded() }
    }
}

struct GalleryCard: View {
    let item: GalleryItem
    let preview: NSImage?
    let installed: Bool
    let busy: Bool
    let action: (Bool) -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    ZStack {
                        LinearGradient(colors: [Theme.panelHi, Theme.blood.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        if let preview {
                            Image(nsImage: preview).resizable().scaledToFill()
                                .transition(.opacity)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .scaleEffect(hover ? 1.05 : 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Label(item.type == "shader" ? tr("Шейдер") : tr("Сцена"),
                          systemImage: item.type == "shader" ? "sparkles" : "square.3.layers.3d")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(.black.opacity(0.5))).padding(8)
                }
                .overlay(alignment: .topTrailing) {
                    if installed {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Theme.crimson)
                            .font(.system(size: 18)).padding(8).crimsonGlow(8)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(hover ? Theme.crimson.opacity(0.7) : Theme.stroke))
                .shadow(color: hover ? Theme.crimson.opacity(0.3) : .black.opacity(0.3), radius: hover ? 16 : 6, y: hover ? 8 : 3)

            Text(item.localizedTitle).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text)
            Text(item.localizedDescription).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button { action(true) } label: {
                    if busy { ProgressView().controlSize(.small).frame(width: 60) }
                    else { Label(installed ? tr("Применить") : tr("Установить"), systemImage: installed ? "play.fill" : "arrow.down.circle.fill") }
                }
                .buttonStyle(CrimsonButtonStyle())
                .disabled(busy)
                if !installed {
                    Button { action(false) } label: { Image(systemName: "plus") }
                        .buttonStyle(GhostButtonStyle(compact: true))
                        .help(tr("Только добавить в библиотеку"))
                        .disabled(busy)
                }
                Spacer()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hover ? Theme.panel : Color.clear))
        .offset(y: hover ? -2 : 0)
        .animation(Theme.snappy, value: hover)
        .onHover { hover = $0 }
    }
}

// MARK: - Обновления

/// Баннер «Доступно обновление» в главном окне.
struct UpdateBanner: View {
    @ObservedObject var updater = AppState.shared.updater

    var body: some View {
        Group {
            switch updater.state {
            case .available(let v):
                bar(icon: "arrow.down.circle.fill", text: tr("Доступна версия %@", v)) {
                    Button(tr("Обновить")) { updater.installUpdate() }.buttonStyle(CrimsonButtonStyle())
                }
            case .downloading(let p):
                bar(icon: "arrow.down.circle", text: tr("Загрузка обновления… %@%", String(Int(p * 100)))) {
                    ProgressView(value: p).frame(width: 120).tint(Theme.crimson)
                }
            case .installing:
                bar(icon: "gearshape.2.fill", text: tr("Установка и перезапуск…")) { ProgressView().controlSize(.small) }
            default:
                EmptyView()
            }
        }
        .animation(Theme.spring, value: updater.state)
    }

    private func bar<T: View>(icon: String, text: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.scarlet).symbolEffect(.pulse)
            Text(text).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panelHi))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.crimson.opacity(0.5)))
        .padding(.horizontal, 16).padding(.top, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Раздел «Обновления» в настройках.
struct UpdateSettingsSection: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var updater = AppState.shared.updater

    var body: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Установлена версия %@", RemoteConfig.appVersion)).foregroundStyle(Theme.text)
                    Text(statusText).font(.caption).foregroundStyle(Theme.text2)
                }
                Spacer()
                if updater.updateAvailable {
                    Button(tr("Обновить")) { updater.installUpdate() }.buttonStyle(CrimsonButtonStyle())
                } else {
                    Button(tr("Проверить")) { updater.check() }
                        .buttonStyle(GhostButtonStyle(compact: true))
                        .disabled(updater.state == .checking)
                }
            }
            Toggle(tr("Проверять обновления автоматически"), isOn: Binding(get: { app.settings.autoCheckUpdates },
                                                                          set: { app.settings.autoCheckUpdates = $0 }))
        } header: {
            Text(tr("Обновления"))
        } footer: {
            Text(tr("Новые версии приходят из релизов GitHub. Обновление скачивается, проверяется и устанавливается, приложение перезапускается само."))
        }
    }

    private var statusText: String {
        switch updater.state {
        case .idle: return updater.lastChecked == nil ? tr("Ещё не проверялось") : tr("Проверено")
        case .checking: return tr("Проверка…")
        case .upToDate: return tr("У вас последняя версия")
        case .available(let v): return tr("Доступна версия %@", v)
        case .downloading(let p): return tr("Загрузка… %@%", String(Int(p * 100)))
        case .installing: return tr("Установка…")
        case .failed(let e): return tr("Ошибка: %@", e)
        }
    }
}
