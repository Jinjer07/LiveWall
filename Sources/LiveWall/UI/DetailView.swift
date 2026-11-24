import SwiftUI

struct WallpaperDetailView: View {
    let itemID: String
    var onClose: (() -> Void)? = nil
    @EnvironmentObject var app: AppState
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var engine: WallpaperEngine

    @State private var title = ""
    @State private var tags = ""
    @State private var showCode = false
    @State private var confirmDelete = false

    private var item: WallpaperItem? { library.item(itemID) }

    private func mutate(immediate: Bool = true, _ f: (inout WallpaperItem) -> Void) {
        guard var it = library.item(itemID) else { return }
        f(&it)
        library.update(it, immediate: immediate)
    }

    var body: some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(tr("ДЕТАЛИ")).font(.system(size: 11, weight: .bold)).tracking(3).foregroundStyle(Theme.scarlet)
                        Spacer()
                        if let onClose {
                            Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle())
                        }
                    }
                    Thumbnail(item: item, version: library.thumbVersion)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
                        .shadow(color: Theme.crimson.opacity(engine.inUse.contains(item.id) ? 0.45 : 0), radius: 18)
                        .id(item.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))

                    TextField(tr("Название"), text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .onSubmit { mutate { $0.title = title } }

                    HStack(spacing: 8) {
                        Label(item.type.title, systemImage: item.type.symbol)
                        if item.source == .steam {
                            Label(item.workshopID.map { "Steam #\($0)" } ?? "Wallpaper Engine", systemImage: "cloud")
                        }
                        Spacer()
                        Button {
                            mutate { $0.favorite.toggle() }
                        } label: { Image(systemName: item.favorite ? "star.fill" : "star").foregroundStyle(item.favorite ? .yellow : .secondary) }
                        .buttonStyle(.borderless)
                    }
                    .font(.callout).foregroundStyle(.secondary)

                    TextField(tr("Теги через запятую"), text: $tags)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Capsule().fill(Theme.panel))
                        .overlay(Capsule().stroke(Theme.stroke))
                        .onSubmit {
                            mutate { $0.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                        }

                    applySection(item)

                    if let err = engine.errors[item.id] {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }

                    if !item.properties.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(tr("НАСТРОЙКИ ОБОЕВ")).font(.system(size: 11, weight: .bold)).tracking(2).foregroundStyle(Theme.scarlet)
                            ForEach(item.properties.sorted { $0.order < $1.order }) { p in
                                PropertyRow(prop: p) { v in setProperty(p.key, v) }
                            }
                            Button(tr("Сбросить настройки")) { resetProperties(item) }
                                .buttonStyle(GhostButtonStyle(compact: true))
                        }
                        .toggleStyle(CrimsonToggleStyle())
                        .panel()
                    }

                    actions(item)
                }
                .padding(14)
            }
            .onAppear { sync(item) }
            .onChange(of: itemID) { _, _ in if let i = self.item { sync(i) } }
            .sheet(isPresented: $showCode) { ShaderCodeEditor(itemID: item.id) }
            .confirmationDialog(tr("Удалить «%@»?", item.title), isPresented: $confirmDelete) {
                Button(tr("Удалить"), role: .destructive) { app.remove(item) }
            } message: {
                Text(library.isManaged(item) ? tr("Файлы обоев будут перемещены в Корзину.") : tr("Обои будут убраны из библиотеки, исходные файлы останутся на месте."))
            }
        }
    }

    private func sync(_ item: WallpaperItem) {
        title = item.title
        tags = item.tags.joined(separator: ", ")
    }

    @ViewBuilder
    private func applySection(_ item: WallpaperItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                app.apply(item.id)
                app.showToast(tr("Применено: %@", item.title))
            } label: {
                Label(app.settings.spanMode ? tr("Растянуть на все экраны") : tr("Применить на все экраны"), systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(CrimsonButtonStyle(large: true))

            if engine.screens.count > 1 && !app.settings.spanMode {
                HStack {
                    ForEach(engine.screens) { s in
                        Button(s.name) { app.apply(item.id, screen: s.key) }
                            .lineLimit(1)
                            .buttonStyle(GhostButtonStyle(compact: true))
                    }
                }
            }
            if engine.inUse.contains(item.id) {
                Button(tr("Снять с рабочего стола")) {
                    for s in engine.screens where engine.desiredItem(for: s.key) == item.id { app.apply(nil, screen: s.key) }
                    if app.settings.spanMode { app.apply(nil) }
                }
                .buttonStyle(GhostButtonStyle(compact: true))
            }
        }
    }

    @ViewBuilder
    private func actions(_ item: WallpaperItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.type == .scene {
                Button { app.openEditor(item) } label: { Label(tr("Открыть в редакторе сцен"), systemImage: "square.3.layers.3d") }
            }
            if item.type == .shader {
                Button { showCode = true } label: { Label(tr("Редактировать код шейдера"), systemImage: "chevron.left.forwardslash.chevron.right") }
            }
            Button {
                engine.snapshotActive(itemID: item.id) { img in
                    if let img { library.savePreview(img, for: item.id); app.showToast(tr("Превью обновлено")) }
                    else { app.showToast(tr("Сначала примените обои — превью снимается с рабочего стола")) }
                }
            } label: { Label(tr("Обновить превью с рабочего стола"), systemImage: "camera") }
            Button { engine.reload(itemID: item.id) } label: { Label(tr("Перезапустить обои"), systemImage: "arrow.clockwise") }
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.entryURL]) } label: { Label(tr("Показать в Finder"), systemImage: "folder") }
            Button {
                guard let url = Panels.save(name: item.title + ".wallpkg", ext: "wallpkg") else { return }
                do { try library.exportPackage(item, to: url); app.showToast(tr("Экспортировано")) }
                catch { app.showToast(tr("Ошибка: %@", error.localizedDescription)) }
            } label: { Label(tr("Экспорт в .wallpkg"), systemImage: "square.and.arrow.up") }
            Button(role: .destructive) { confirmDelete = true } label: { Label(tr("Удалить"), systemImage: "trash").foregroundStyle(Theme.scarlet) }
        }
        .buttonStyle(ActionRowStyle())
    }

    private func setProperty(_ key: String, _ v: PropertyValue) {
        mutate(immediate: false) { it in
            if let i = it.properties.firstIndex(where: { $0.key == key }) { it.properties[i].value = v }
        }
        if let it = library.item(itemID) { engine.updateProperties(it) }
    }

    private func resetProperties(_ item: WallpaperItem) {
        var defaults: [WallpaperProperty] = DefaultProps.forType(item.type)
        switch item.type {
        case .shader:
            if let src = try? String(contentsOf: item.entryURL, encoding: .utf8) { defaults += ShaderParser.properties(from: src) }
        case .web, .video:
            if item.source == .steam, let j = WEProject.readJSON(item.folderURL) { defaults += WEProject.properties(j) }
            else if item.type == .web { defaults = item.properties }
        default: break
        }
        mutate { $0.properties = defaults }
        if let it = library.item(itemID) { engine.updateProperties(it) }
    }
}

struct ShaderCodeEditor: View {
    let itemID: String
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var engine: WallpaperEngine
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("Код шейдера")).font(.headline)
                Spacer()
                Text("mainImage(out vec4 fragColor, in vec2 fragCoord) · iTime · iResolution · iMouse · iAudio · iSpectrum")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $code)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if let err = engine.errors[itemID] {
                ScrollView { Text(err).font(.system(size: 11, design: .monospaced)).foregroundStyle(.orange).textSelection(.enabled) }
                    .frame(maxHeight: 90)
            }
            HStack {
                Text(tr("Изменения применяются к обоям на рабочем столе.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Закрыть")) { dismiss() }
                Button(tr("Сохранить и применить")) { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 600)
        .onAppear {
            if let it = library.item(itemID) { code = (try? String(contentsOf: it.entryURL, encoding: .utf8)) ?? "" }
        }
    }

    private func save() {
        guard var it = library.item(itemID) else { return }
        try? code.write(to: it.entryURL, atomically: true, encoding: .utf8)
        let fresh = DefaultProps.forType(.shader) + ShaderParser.properties(from: code)
        it.properties = fresh.merged(keepingValuesFrom: it.properties)
        library.update(it)
        engine.errors[itemID] = nil
        engine.reload(itemID: itemID)
        if !engine.inUse.contains(itemID) { AppState.shared.apply(itemID) }
    }
}

/// Строка действия в панели деталей.
struct ActionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }
    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hover ? Theme.text : Theme.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9).fill(hover ? Theme.panelHi : Color.clear))
                .offset(x: hover ? 3 : 0)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(Theme.snappy, value: hover)
                .onHover { hover = $0 }
        }
    }
}
