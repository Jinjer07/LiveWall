import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var engine: WallpaperEngine

    enum Filter: Hashable { case all, favorites, type(WallpaperType) }

    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var tagFilter: String? = nil
    @State private var selectedID: String?
    @State private var dropTargeted = false

    private var filters: [Filter] { [.all, .favorites] + WallpaperType.allCases.map { Filter.type($0) } }

    private var filtered: [WallpaperItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let f = filter, tag = tagFilter
        let result: [WallpaperItem] = library.items.filter { (it: WallpaperItem) -> Bool in
            switch f {
            case .all: break
            case .favorites: if !it.favorite { return false }
            case .type(let t): if it.type != t { return false }
            }
            if let tag, !it.tags.contains(tag) { return false }
            if q.isEmpty { return true }
            if it.title.lowercased().contains(q) { return true }
            return it.tags.contains { (t: String) -> Bool in t.lowercased().contains(q) }
        }
        return result.sorted { (a: WallpaperItem, b: WallpaperItem) -> Bool in a.added > b.added }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PageHeader(title: "Библиотека", subtitle: "\(library.items.count) обоев · двойной клик — применить") {
                    HStack(spacing: 10) {
                        SearchField(text: $search, prompt: "Поиск").frame(width: 200)
                        addMenu
                    }
                }
                HStack(spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        ChipBar(items: filters, selection: $filter, label: label(for:), icon: icon(for:))
                    }
                    if !library.allTags.isEmpty {
                        Menu {
                            Button("Все теги") { tagFilter = nil }
                            ForEach(library.allTags, id: \.self) { t in Button("#\(t)") { tagFilter = t } }
                        } label: {
                            Label(tagFilter.map { "#\($0)" } ?? "Теги", systemImage: "number")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .foregroundStyle(tagFilter == nil ? Theme.text2 : Theme.scarlet)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)

                grid
            }

            if let id = selectedID, library.item(id) != nil {
                Rectangle().fill(Theme.stroke).frame(width: 1)
                WallpaperDetailView(itemID: id) { withAnimation(Theme.spring) { selectedID = nil } }
                    .frame(width: 300)
                    .background(Theme.bg)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: selectedID)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadDropped(providers); return true
        }
        .overlay {
            if dropTargeted {
                ZStack {
                    Theme.bg.opacity(0.75)
                    VStack(spacing: 14) {
                        Image(systemName: "arrow.down.to.line.circle.fill")
                            .font(.system(size: 64)).foregroundStyle(Theme.redGradient)
                            .crimsonGlow(20)
                            .symbolEffect(.bounce, options: .repeating)
                        Text("Отпустите, чтобы добавить в библиотеку")
                            .font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.crimson, style: StrokeStyle(lineWidth: 2, dash: [10, 8])).padding(14))
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: dropTargeted)
    }

    // MARK: Сетка

    private var grid: some View {
        let items = filtered
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 14)], spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    WallpaperCard(item: item, selected: selectedID == item.id,
                                  active: engine.inUse.contains(item.id), version: library.thumbVersion)
                        .onTapGesture(count: 2) {
                            app.apply(item.id)
                            app.showToast("Применено: \(item.title)")
                        }
                        .onTapGesture { withAnimation(Theme.spring) { selectedID = item.id } }
                        .contextMenu { contextMenu(item) }
                        .staggered(idx, base: 0.025)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .padding(.top, 4)
        }
        .overlay {
            if library.items.isEmpty {
                EmptyState(icon: "photo.on.rectangle.angled", title: "Библиотека пуста",
                           text: "Перетащите сюда видео, картинки, GIF, папки с веб-обоями, шейдеры .frag или пакеты .wallpkg")
            } else if items.isEmpty {
                EmptyState(icon: "magnifyingglass", title: "Ничего не найдено", text: "Попробуйте другой запрос или фильтр")
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Button("Импортировать файлы или папки…") { report(library.importURLs(Panels.openFiles())) }
            Button("Импортировать пакет .wallpkg…") {
                let urls = Panels.openFiles(types: [UTType(filenameExtension: "wallpkg") ?? .zip], directories: false)
                report(library.importURLs(urls))
            }
            Divider()
            Button("Новый шейдер") {
                let it = library.createShader()
                withAnimation(Theme.spring) { selectedID = it.id }
            }
            Button("Новая сцена…") { app.openEditor(nil) }
        } label: {
            Label("Добавить", systemImage: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(Theme.redGradient))
                .crimsonGlow(10, opacity: 0.45)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverLift(scale: 1.04, glow: false)
    }

    private func label(for f: Filter) -> String {
        switch f {
        case .all: return "Все"
        case .favorites: return "Избранное"
        case .type(let t): return t.title
        }
    }

    private func icon(for f: Filter) -> String? {
        switch f {
        case .all: return nil
        case .favorites: return "star.fill"
        case .type(let t): return t.symbol
        }
    }

    @ViewBuilder
    private func contextMenu(_ item: WallpaperItem) -> some View {
        Button("Применить на все экраны") { app.apply(item.id) }
        if engine.screens.count > 1 && !app.settings.spanMode {
            Menu("Применить на экран") {
                ForEach(engine.screens) { s in Button(s.name) { app.apply(item.id, screen: s.key) } }
            }
        }
        Divider()
        Button(item.favorite ? "Убрать из избранного" : "В избранное") {
            var it = item; it.favorite.toggle(); library.update(it)
        }
        if item.type == .scene { Button("Открыть в редакторе") { app.openEditor(item) } }
        Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.entryURL]) }
        Button("Экспорт в .wallpkg…") { export(item) }
        Divider()
        Button("Удалить", role: .destructive) {
            if selectedID == item.id { selectedID = nil }
            app.remove(item)
        }
    }

    private func export(_ item: WallpaperItem) {
        guard let url = Panels.save(name: item.title + ".wallpkg", ext: "wallpkg") else { return }
        do { try library.exportPackage(item, to: url); app.showToast("Экспортировано: \(url.lastPathComponent)") }
        catch { app.showToast("Ошибка экспорта: \(error.localizedDescription)") }
    }

    private func report(_ r: (imported: [WallpaperItem], errors: [String])) {
        if let first = r.imported.first { withAnimation(Theme.spring) { selectedID = first.id } }
        if !r.errors.isEmpty {
            app.showToast("Не удалось: " + r.errors.joined(separator: "; "))
        } else if !r.imported.isEmpty {
            app.showToast("Добавлено: \(r.imported.count)")
        }
    }

    private func loadDropped(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for p in providers {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                if let d = data as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) {
                    lock.lock(); urls.append(u); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { report(library.importURLs(urls)) }
        }
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let text: String
    @State private var float = false
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Theme.redGradient)
                .offset(y: float ? -6 : 6)
                .crimsonGlow(18, opacity: 0.4)
            Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .onAppear { withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { float = true } }
    }
}

struct WallpaperCard: View {
    let item: WallpaperItem
    let selected: Bool
    let active: Bool
    let version: Int
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Thumbnail(item: item, version: version)
                .scaleEffect(hover ? 1.04 : 1)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .opacity(hover ? 1 : 0.6)
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        Image(systemName: item.type.symbol)
                        Text(item.type.title)
                        if item.source == .steam { Image(systemName: "cloud.fill") }
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.5)))
                    .padding(8)
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 5) {
                        if active {
                            HStack(spacing: 5) { LiveDot(); Text("LIVE").font(.system(size: 10, weight: .heavy)) }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(Theme.crimson.opacity(0.85)))
                                .crimsonGlow(8)
                        }
                        if item.favorite {
                            Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.yellow)
                                .padding(5).background(Circle().fill(.black.opacity(0.5)))
                        }
                    }
                    .padding(8)
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.redGradient))
                        .crimsonGlow(10)
                        .scaleEffect(hover ? 1 : 0.4)
                        .opacity(hover ? 1 : 0)
                        .padding(9)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(selected ? AnyShapeStyle(Theme.redHGradient) : AnyShapeStyle(hover ? Theme.strokeHi : Theme.stroke),
                                lineWidth: selected ? 2.5 : 1)
                }
                .shadow(color: selected ? Theme.crimson.opacity(0.5) : (hover ? Theme.crimson.opacity(0.3) : .black.opacity(0.3)),
                        radius: selected || hover ? 16 : 6, y: hover ? 8 : 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(selected ? Theme.scarlet : Theme.text).lineLimit(1)
                Text(item.tags.isEmpty ? item.type.title : item.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .offset(y: hover ? -3 : 0)
        .animation(Theme.snappy, value: hover)
        .animation(Theme.spring, value: selected)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}
