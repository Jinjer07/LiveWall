import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct Thumbnail: View {
    let item: WallpaperItem
    var version: Int = 0
    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                ZStack {
                    LinearGradient(colors: [Theme.panelHi, Theme.blood.opacity(0.55)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    if let img = ThumbCache.image(for: item.previewURL) {
                        Image(nsImage: img).resizable().scaledToFill()
                    } else {
                        Image(systemName: item.type.symbol)
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(Theme.scarlet.opacity(0.85))
                    }
                }
                .id(version)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var format: String = "%.2f"

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).foregroundStyle(Theme.text)
                Spacer()
                Text(String(format: format, value)).monospacedDigit().foregroundStyle(Theme.scarlet)
                    .font(.system(size: 12, weight: .semibold))
            }
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
        }
    }
}

/// Редактор одного свойства обоев.
struct PropertyRow: View {
    let prop: WallpaperProperty
    let onChange: (PropertyValue) -> Void
    @State private var text = ""

    private var sliderRow: some View {
        let lo: Double = prop.min ?? 0
        let hi: Double = Swift.max(prop.max ?? 1, lo + 0.0001)
        let step: Double = prop.step ?? 0
        let fmt: String = step >= 1 ? "%.0f" : "%.2f"
        let p = prop
        let change = onChange
        let binding = Binding<Double>(
            get: { Swift.min(Swift.max(p.value.double, lo), hi) },
            set: { change(.number($0)) })
        return SliderRow(title: prop.label, value: binding, range: lo...hi, step: prop.step, format: fmt)
    }

    var body: some View {
        switch prop.kind {
        case .slider:
            sliderRow
        case .color:
            ColorPicker(prop.label, selection: Binding(get: { Color(rgbString: prop.value.string) },
                                                       set: { onChange(.string($0.rgbString)) }), supportsOpacity: false)
        case .bool:
            Toggle(prop.label, isOn: Binding(get: { prop.value.bool }, set: { onChange(.bool($0)) }))
        case .combo:
            Picker(prop.label, selection: Binding(get: { prop.value.string }, set: { onChange(.string($0)) })) {
                ForEach(prop.options ?? [], id: \.value) { o in Text(o.label).tag(o.value) }
            }
        case .text:
            TextField(prop.label, text: $text)
                .onAppear { text = prop.value.string }
                .onSubmit { onChange(.string(text)) }
        }
    }
}

enum Panels {
    @MainActor
    static func openFiles(types: [UTType]? = nil, directories: Bool = true, multiple: Bool = true) -> [URL] {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = directories
        p.allowsMultipleSelection = multiple
        if let types { p.allowedContentTypes = types }
        return p.runModal() == .OK ? p.urls : []
    }

    @MainActor
    static func chooseFolder() -> URL? {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.allowsMultipleSelection = false
        return p.runModal() == .OK ? p.url : nil
    }

    @MainActor
    static func save(name: String, ext: String) -> URL? {
        let p = NSSavePanel()
        p.nameFieldStringValue = name
        if let t = UTType(filenameExtension: ext) { p.allowedContentTypes = [t] }
        return p.runModal() == .OK ? p.url : nil
    }
}

extension View {
    func cardStyle() -> some View {
        self.panel(radius: 12, padding: 12)
    }
}
