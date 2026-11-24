import SwiftUI
import WebKit
import Combine
import UniformTypeIdentifiers

// MARK: - Превью сцены в редакторе

@MainActor
final class ScenePreview: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private(set) var webView: WKWebView!
    private var loaded = false
    private var sceneScript: String?
    private var extra: [String] = []
    private var audioSub: AnyCancellable?

    var onSelect: ((String?) -> Void)?
    var onMove: ((String, Double, Double) -> Void)?
    var onError: ((String) -> Void)?

    override init() {
        super.init()
        webView = WebViewFactory.make(handler: self)
        webView.navigationDelegate = self
        webView.loadFileURL(Paths.runtime.appendingPathComponent("scene.html"),
                            allowingReadAccessTo: URL(fileURLWithPath: "/", isDirectory: true))
        audioSub = AppState.shared.audioSubject.sink { [weak self] s in
            guard let self, self.loaded, self.webView.window != nil else { return }
            let arr = s.map { String(format: "%.3f", $0) }.joined(separator: ",")
            self.webView.evaluateJavaScript("__lwAudio([\(arr)])", completionHandler: nil)
        }
    }

    func loadScene(json: String, base: URL) {
        let s = "__lwLoadScene(\(json), \(jsString(base.absoluteString)), true)"
        sceneScript = s
        if loaded { webView.evaluateJavaScript(s, completionHandler: nil) }
    }

    func js(_ s: String) {
        if loaded { webView.evaluateJavaScript(s, completionHandler: nil) } else { extra.append(s) }
    }

    func snapshot(_ done: @escaping (NSImage?) -> Void) {
        canvasSnapshot(webView, done)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        webView.evaluateJavaScript("__lwFPS(60)", completionHandler: nil)
        if let s = sceneScript { webView.evaluateJavaScript(s, completionHandler: nil) }
        for s in extra { webView.evaluateJavaScript(s, completionHandler: nil) }
        extra.removeAll()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        webView.reload()
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let b = m.body as? [String: Any], let type = b["type"] as? String else { return }
        switch type {
        case "select": onSelect?(b["id"] as? String)
        case "move":
            if let id = b["id"] as? String, let x = (b["x"] as? NSNumber)?.doubleValue, let y = (b["y"] as? NSNumber)?.doubleValue {
                onMove?(id, x, y)
            }
        case "error": onError?(b["message"] as? String ?? "")
        default: break
        }
    }
}

struct ScenePreviewView: NSViewRepresentable {
    let preview: ScenePreview
    func makeNSView(context: Context) -> WKWebView { preview.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - Модель редактора

@MainActor
final class SceneEditorModel: ObservableObject {
    @Published var doc = SceneDoc() {
        didSet {
            guard doc != oldValue else { return }
            dirty = true
            if !suppressPush { push() }
        }
    }
    @Published var title = tr("Новая сцена")
    @Published var selectedLayerID: String? {
        didSet { preview.js("__lwSelect(\(jsString(selectedLayerID)))") }
    }
    @Published var dirty = false
    @Published var previewParallax = false {
        didSet { preview.js("__lwEditorParallax(\(previewParallax))") }
    }
    @Published var lastError: String?
    @Published private(set) var itemID: String?
    private(set) var folder: URL

    let preview = ScenePreview()
    private var suppressPush = false

    init() {
        folder = AppState.shared.library.newFolder()
        doc = Self.starterDoc()
        dirty = false
        preview.onSelect = { [weak self] id in self?.selectedLayerID = id }
        preview.onMove = { [weak self] id, x, y in
            guard let self, let i = self.doc.layers.firstIndex(where: { $0.id == id }) else { return }
            self.suppressPush = true
            self.doc.layers[i].x = x
            self.doc.layers[i].y = y
            self.suppressPush = false
        }
        preview.onError = { [weak self] m in self?.lastError = m }
        push()
    }

    static func starterDoc() -> SceneDoc {
        var d = SceneDoc()
        if let s = NSScreen.main, s.frame.width > 0 {
            let ratio = Double(s.frame.height / s.frame.width)
            d.height = (1920 * ratio).rounded()
        }
        d.background = "#101426"
        return d
    }

    func push() {
        let json = (try? JSONEncoder().encode(doc)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        preview.loadScene(json: json, base: folder)
    }

    func newScene() {
        itemID = nil
        folder = AppState.shared.library.newFolder()
        title = tr("Новая сцена")
        selectedLayerID = nil
        doc = Self.starterDoc()
        push()
        dirty = false
        lastError = nil
    }

    func open(_ item: WallpaperItem) {
        itemID = item.id
        folder = item.folderURL
        title = item.title
        selectedLayerID = nil
        doc = Persistence.load(SceneDoc.self, from: item.entryURL) ?? SceneDoc()
        push()
        dirty = false
        lastError = nil
    }

    // MARK: Слои

    func binding(for id: String?) -> Binding<SceneLayer>? {
        guard let id, doc.layers.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.doc.layers.first { $0.id == id } ?? SceneLayer(name: "", kind: .image) },
            set: { nv in if let i = self.doc.layers.firstIndex(where: { $0.id == id }) { self.doc.layers[i] = nv } })
    }

    private func append(_ l: SceneLayer) {
        doc.layers.append(l)
        selectedLayerID = l.id
    }

    private func copyAsset(_ url: URL) -> String? {
        var name = url.lastPathComponent.replacingOccurrences(of: "/", with: "_")
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            n += 1; name = "\(base)-\(n).\(ext)"
        }
        do { try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name)); return name }
        catch { lastError = tr("Не удалось скопировать %@: %@", url.lastPathComponent, error.localizedDescription); return nil }
    }

    private func pixelSize(_ url: URL) -> CGSize? {
        guard let rep = NSImageRep(contentsOf: url) ?? NSImage(contentsOf: url)?.representations.first else { return nil }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    func addImageLayer() {
        for url in Panels.openFiles(types: [.image], directories: false) {
            guard let name = copyAsset(url) else { continue }
            var l = SceneLayer(name: url.deletingPathExtension().lastPathComponent, kind: .image)
            l.file = name
            if let s = pixelSize(url), s.width > 0, s.height > 0 {
                let hasImage = doc.layers.contains { $0.kind == .image }
                l.scale = hasImage ? min(doc.width * 0.5 / s.width, doc.height * 0.5 / s.height)
                                   : max(doc.width / s.width, doc.height / s.height)
            }
            append(l)
        }
    }

    func replaceImage(for id: String) {
        guard let url = Panels.openFiles(types: [.image], directories: false, multiple: false).first,
              let name = copyAsset(url), let i = doc.layers.firstIndex(where: { $0.id == id }) else { return }
        doc.layers[i].file = name
    }

    func addParticles(_ p: ParticlePreset) {
        var l = p.make()
        l.width = doc.width; l.height = doc.height
        append(l)
    }

    func addText() {
        var l = SceneLayer(name: tr("Текст"), kind: .text)
        l.text = "{time}"; l.y = 0.45
        append(l)
    }

    func addWidget(_ w: WidgetPreset) {
        var l = SceneLayer(name: w.title, kind: .text)
        l.text = w.text
        l.fontSize = w.fontSize
        l.fontWeight = w.weight
        l.x = w.position.0; l.y = w.position.1
        l.opacity = 0.9
        l.parallax = 0.2
        append(l)
    }

    func addColor() {
        var l = SceneLayer(name: tr("Заливка"), kind: .color)
        l.width = doc.width; l.height = doc.height; l.tint = "#203060"
        append(l)
    }

    func toggleVisible(_ id: String) {
        if let i = doc.layers.firstIndex(where: { $0.id == id }) { doc.layers[i].visible.toggle() }
    }

    /// up = выше в стопке (ближе к зрителю)
    func move(_ id: String?, up: Bool) {
        guard let id, let i = doc.layers.firstIndex(where: { $0.id == id }) else { return }
        let j = up ? i + 1 : i - 1
        guard j >= 0, j < doc.layers.count else { return }
        doc.layers.swapAt(i, j)
    }

    func duplicate(_ id: String?) {
        guard let id, let i = doc.layers.firstIndex(where: { $0.id == id }) else { return }
        var l = doc.layers[i]
        l.id = UUID().uuidString
        l.name += tr(" (копия)")
        l.x = min(1, l.x + 0.02); l.y = min(1, l.y + 0.02)
        doc.layers.insert(l, at: i + 1)
        selectedLayerID = l.id
    }

    func delete(_ id: String?) {
        guard let id else { return }
        doc.layers.removeAll { $0.id == id }
        selectedLayerID = nil
    }

    // MARK: Сохранение

    func save(apply: Bool) {
        let app = AppState.shared
        let lib = app.library
        do {
            try JSONEncoder.lw.encode(doc).write(to: folder.appendingPathComponent("scene.json"))
        } catch {
            lastError = tr("Ошибка сохранения: %@", error.localizedDescription)
            return
        }
        if let id = itemID, var item = lib.item(id) {
            item.title = title
            lib.update(item)
        } else {
            let item = WallpaperItem(id: UUID().uuidString, title: title, type: .scene, folder: folder.path,
                                     entry: "scene.json", properties: DefaultProps.forType(.scene))
            lib.add(item)
            itemID = item.id
        }
        dirty = false
        guard let id = itemID else { return }
        let sel = selectedLayerID
        preview.js("__lwSelect(null)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                self?.preview.snapshot { img in
                    if let img { lib.savePreview(img, for: id) }
                    self?.preview.js("__lwSelect(\(jsString(sel)))")
                }
            }
        }
        app.engine.reload(itemID: id)
        if apply { app.apply(id) }
        app.showToast(apply ? tr("Сцена сохранена и применена") : tr("Сцена сохранена"))
    }
}

// MARK: - Интерфейс редактора

struct SceneEditorView: View {
    @ObservedObject var model: SceneEditorModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: tr("Редактор сцен"), subtitle: model.itemID == nil ? tr("Новая сцена") : tr("Редактирование: %@", model.title)) {
                HStack(spacing: 8) {
                    Button { model.newScene() } label: { Label(tr("Новая"), systemImage: "doc.badge.plus") }
                        .buttonStyle(GhostButtonStyle())
                    Button { model.save(apply: false) } label: { Label(tr("Сохранить"), systemImage: "square.and.arrow.down") }
                        .buttonStyle(GhostButtonStyle())
                        .keyboardShortcut("s", modifiers: .command)
                    Button { model.save(apply: true) } label: { Label(tr("Сохранить и применить"), systemImage: "play.fill") }
                        .buttonStyle(CrimsonButtonStyle())
                }
            }
            editor
        }
    }

    private var editor: some View {
        HSplitView {
            LayersPanel(model: model)
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
            VStack(spacing: 8) {
                HStack {
                    TextField(tr("Название сцены"), text: $model.title)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                    Toggle(tr("Параллакс в превью"), isOn: $model.previewParallax)
                    Spacer()
                    if model.dirty {
                        HStack(spacing: 5) { LiveDot(); Text(tr("Не сохранено")) }
                            .font(.caption).foregroundStyle(Theme.scarlet)
                            .transition(.opacity.combined(with: .scale))
                    }
                }
                ZStack {
                    Color.black
                    ScenePreviewView(preview: model.preview)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: Theme.crimson.opacity(0.25), radius: 24)
                        .aspectRatio(CGFloat(model.doc.width / max(1, model.doc.height)), contentMode: .fit)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                if let e = model.lastError {
                    Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Text(tr("Перетаскивайте слои мышью прямо в превью. Текстовые токены: {time} {time:s} {date} {weekday} {year}"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(minWidth: 480)
            LayerInspector(model: model)
                .frame(minWidth: 290, idealWidth: 330, maxWidth: 400)
        }
    }
}

struct LayersPanel: View {
    @ObservedObject var model: SceneEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tr("Слои")).font(.headline)
                Spacer()
                Menu {
                    Button(tr("Изображение…")) { model.addImageLayer() }
                    Menu(tr("Частицы")) {
                        ForEach(ParticlePreset.allCases) { p in Button(p.title) { model.addParticles(p) } }
                    }
                    Button(tr("Текст / часы")) { model.addText() }
                    Button(tr("Цветная заливка")) { model.addColor() }
                    Menu(tr("Виджет")) {
                        ForEach(WidgetPreset.allCases) { w in Button(w.title) { model.addWidget(w) } }
                    }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(10)
            List(selection: $model.selectedLayerID) {
                ForEach(Array(model.doc.layers.reversed())) { layer in
                    HStack {
                        Image(systemName: layer.kind.symbol).frame(width: 18)
                        Text(tr(layer.name)).lineLimit(1)
                            .foregroundStyle(layer.visible ? .primary : .secondary)
                        Spacer()
                        Button { model.toggleVisible(layer.id) } label: {
                            Image(systemName: layer.visible ? "eye" : "eye.slash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .tag(layer.id)
                }
            }
            Divider()
            HStack(spacing: 12) {
                Button { model.move(model.selectedLayerID, up: true) } label: { Image(systemName: "arrow.up") }
                    .help(tr("Выше"))
                Button { model.move(model.selectedLayerID, up: false) } label: { Image(systemName: "arrow.down") }
                    .help(tr("Ниже"))
                Button { model.duplicate(model.selectedLayerID) } label: { Image(systemName: "plus.square.on.square") }
                    .help(tr("Дублировать"))
                Spacer()
                Button { model.delete(model.selectedLayerID) } label: { Image(systemName: "trash") }
                    .help(tr("Удалить"))
            }
            .buttonStyle(.borderless)
            .disabled(model.selectedLayerID == nil)
            .padding(10)
        }
    }
}

struct LayerInspector: View {
    @ObservedObject var model: SceneEditorModel

    var body: some View {
        if let b = model.binding(for: model.selectedLayerID) {
            layerForm(b)
        } else {
            sceneForm
        }
    }

    private var aspectOptions: [(String, Double)] {
        var opts: [(String, Double)] = [("16:9", 1080), ("16:10", 1200), ("21:9", 823)]
        if let s = NSScreen.main, s.frame.width > 0 {
            let h = Double((1920 * s.frame.height / s.frame.width).rounded())
            if !opts.contains(where: { $0.1 == h }) { opts.append((tr("Как у экрана"), h)) }
        }
        let cur = model.doc.height
        if !opts.contains(where: { $0.1 == cur }) { opts.append((tr("Своё"), cur)) }
        return opts
    }

    private var sceneForm: some View {
        Form {
            Section(tr("Сцена")) {
                LabeledContent(tr("Размер макета")) { Text("\(Int(model.doc.width)) × \(Int(model.doc.height))") }
                Picker(tr("Соотношение сторон"), selection: Binding(get: { model.doc.height }, set: { model.doc.height = $0; model.doc.width = 1920 })) {
                    ForEach(aspectOptions, id: \.1) { opt in
                        Text(opt.0).tag(opt.1)
                    }
                }
                ColorPicker(tr("Фон"), selection: $model.doc.background.hexColor, supportsOpacity: false)
                Toggle(tr("Адаптация к времени суток и погоде"),
                       isOn: Binding(get: { model.doc.ambient ?? false }, set: { model.doc.ambient = $0 }))
                    .toggleStyle(CrimsonToggleStyle())
                if model.doc.ambient == true {
                    Toggle(tr("Осадки по текущей погоде"),
                           isOn: Binding(get: { model.doc.ambientPrecip ?? true }, set: { model.doc.ambientPrecip = $0 }))
                        .toggleStyle(CrimsonToggleStyle())
                }
            }
            Section {
                Text(tr("Выберите слой слева или кликните по нему в превью. Добавить слой — кнопка «+»."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .toggleStyle(CrimsonToggleStyle())
    }

    @ViewBuilder
    private func layerForm(_ l: Binding<SceneLayer>) -> some View {
        let kind = l.wrappedValue.kind
        Form {
            Section(tr("Слой: %@", kind.title)) {
                TextField(tr("Название"), text: l.name)
                Toggle(tr("Видимый"), isOn: l.visible)
                SliderRow(title: "X", value: l.x, range: -0.5...1.5)
                SliderRow(title: "Y", value: l.y, range: -0.5...1.5)
                if kind != .particles {
                    SliderRow(title: tr("Масштаб"), value: l.scale, range: 0.02...5)
                    SliderRow(title: tr("Поворот"), value: l.rotation, range: -180...180, format: "%.0f°")
                    SliderRow(title: tr("Вращение, °/с"), value: l.rotationSpeed, range: -120...120, format: "%.0f")
                }
                SliderRow(title: tr("Прозрачность"), value: l.opacity, range: 0...1)
                SliderRow(title: tr("Параллакс (глубина)"), value: l.parallax, range: 0...2)
                Picker(tr("Наложение"), selection: l.blend) {
                    Text(tr("Обычное")).tag("normal")
                    Text(tr("Сложение (свет)")).tag("add")
                    Text(tr("Экран")).tag("screen")
                    Text(tr("Умножение")).tag("multiply")
                }
                if kind != .particles {
                    SliderRow(title: tr("Мягкие края"),
                              value: Binding(get: { l.wrappedValue.feather ?? 0 }, set: { l.wrappedValue.feather = $0 }),
                              range: 0...0.5)
                }
            }

            switch kind {
            case .image:
                Section(tr("Изображение")) {
                    LabeledContent(tr("Файл")) { Text(l.wrappedValue.file ?? "—").lineLimit(1).truncationMode(.middle) }
                    Button(tr("Заменить…")) { model.replaceImage(for: l.wrappedValue.id) }
                    ColorPicker(tr("Оттенок (умножение)"), selection: l.tint.hexColor, supportsOpacity: false)
                }
            case .color:
                Section(tr("Заливка")) {
                    ColorPicker(tr("Цвет"), selection: l.tint.hexColor, supportsOpacity: false)
                    SliderRow(title: tr("Ширина"), value: l.width, range: 10...4000, format: "%.0f")
                    SliderRow(title: tr("Высота"), value: l.height, range: 10...4000, format: "%.0f")
                }
            case .text:
                Section(tr("Текст")) {
                    TextField(tr("Текст"), text: l.text, axis: .vertical).lineLimit(1...4)
                    SliderRow(title: tr("Размер шрифта"), value: l.fontSize, range: 10...600, format: "%.0f")
                    Picker(tr("Насыщенность"), selection: l.fontWeight) {
                        Text(tr("Тонкий")).tag("200"); Text(tr("Лёгкий")).tag("300"); Text(tr("Обычный")).tag("400")
                        Text(tr("Полужирный")).tag("600"); Text(tr("Жирный")).tag("800")
                    }
                    ColorPicker(tr("Цвет"), selection: l.textColor.hexColor, supportsOpacity: false)
                }
            case .particles:
                particlesSection(l)
            }

            if kind != .particles {
                Section(tr("Эффекты")) {
                    Toggle(tr("Волны"), isOn: l.waveEnabled)
                    if l.wrappedValue.waveEnabled {
                        SliderRow(title: tr("Амплитуда"), value: l.waveAmplitude, range: 0...5)
                        SliderRow(title: tr("Частота"), value: l.waveFrequency, range: 0.1...20)
                        SliderRow(title: tr("Скорость"), value: l.waveSpeed, range: -10...10)
                        Toggle(tr("Вертикальные"), isOn: l.waveVertical)
                    }
                    Toggle(tr("Свечение"), isOn: l.glowEnabled)
                    if l.wrappedValue.glowEnabled {
                        SliderRow(title: tr("Радиус"), value: l.glowRadius, range: 0.5...20)
                        SliderRow(title: tr("Интенсивность"), value: l.glowIntensity, range: 0...3)
                        ColorPicker(tr("Цвет свечения"), selection: l.glowColor.hexColor, supportsOpacity: false)
                    }
                }
                Section(tr("Цветокоррекция")) {
                    SliderRow(title: tr("Тон"), value: l.hue, range: -180...180, format: "%.0f°")
                    SliderRow(title: tr("Насыщенность"), value: l.saturation, range: 0...3)
                    SliderRow(title: tr("Яркость"), value: l.brightness, range: 0...3)
                }
                Section(tr("Реакция на звук")) {
                    SliderRow(title: tr("Пульсация"), value: l.audioPulse, range: 0...1)
                    Picker(tr("Полоса"), selection: l.audioBand) {
                        Text(tr("Бас")).tag("bass"); Text(tr("Середина")).tag("mid"); Text(tr("Верха")).tag("high"); Text(tr("Общий уровень")).tag("level")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .toggleStyle(CrimsonToggleStyle())
    }

    @ViewBuilder
    private func particlesSection(_ l: Binding<SceneLayer>) -> some View {
        Section(tr("Частицы")) {
            Picker(tr("Источник"), selection: l.pEmitter) {
                Text(tr("Сверху")).tag("top"); Text(tr("Снизу")).tag("bottom")
                Text(tr("По всему экрану")).tag("full"); Text(tr("Из точки X/Y")).tag("point")
            }
            SliderRow(title: tr("Количество"), value: Binding(get: { Double(l.wrappedValue.pCount) }, set: { l.wrappedValue.pCount = Int($0) }),
                      range: 0...3000, step: 10, format: "%.0f")
            SliderRow(title: tr("Размер от"), value: l.pSizeMin, range: 0.5...80, format: "%.1f")
            SliderRow(title: tr("Размер до"), value: l.pSizeMax, range: 0.5...80, format: "%.1f")
            SliderRow(title: tr("Скорость"), value: l.pSpeed, range: 0...1500, format: "%.0f")
            SliderRow(title: tr("Направление"), value: l.pDirection, range: 0...360, format: "%.0f°")
            SliderRow(title: tr("Разброс"), value: l.pSpread, range: 0...180, format: "%.0f°")
            SliderRow(title: tr("Время жизни, с"), value: l.pLifetime, range: 0.5...60, format: "%.1f")
            SliderRow(title: tr("Гравитация"), value: l.pGravity, range: -500...500, format: "%.0f")
            SliderRow(title: tr("Покачивание"), value: l.pWobble, range: 0...100, format: "%.0f")
            ColorPicker(tr("Цвет 1"), selection: l.pColor.hexColor, supportsOpacity: false)
            ColorPicker(tr("Цвет 2"), selection: l.pColor2.hexColor, supportsOpacity: false)
            Picker(tr("Форма"), selection: l.pShape) {
                Text(tr("Мягкая точка")).tag("soft"); Text(tr("Кольцо")).tag("circle")
                Text(tr("Штрих (дождь)")).tag("streak"); Text(tr("Своя картинка")).tag("image")
            }
            if l.wrappedValue.pShape == "image" {
                Button(l.wrappedValue.file == nil ? tr("Выбрать картинку…") : tr("Заменить картинку…")) { model.replaceImage(for: l.wrappedValue.id) }
            }
            Toggle(tr("Разлетаются от курсора"), isOn: l.pMouseRepel)
            SliderRow(title: tr("Реакция на бас"), value: l.pAudio, range: 0...2)
        }
    }
}
