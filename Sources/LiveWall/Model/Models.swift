import Foundation

// MARK: - Типы обоев

enum WallpaperType: String, Codable, CaseIterable, Identifiable {
    case video, web, image, slideshow, shader, scene
    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: return tr("Видео")
        case .web: return tr("Веб")
        case .image: return tr("Картинка")
        case .slideshow: return tr("Слайдшоу")
        case .shader: return tr("Шейдер")
        case .scene: return tr("Сцена")
        }
    }

    var symbol: String {
        switch self {
        case .video: return "film"
        case .web: return "globe"
        case .image: return "photo"
        case .slideshow: return "photo.on.rectangle"
        case .shader: return "sparkles"
        case .scene: return "square.3.layers.3d"
        }
    }
}

enum WallpaperSource: String, Codable { case local, steam }

// MARK: - Свойства (совместимы с форматом Wallpaper Engine)

enum PropertyKind: String, Codable { case slider, color, bool, combo, text }

struct PropertyOption: Codable, Hashable {
    var label: String
    var value: String
}

enum PropertyValue: Codable, Hashable {
    case number(Double)
    case string(String)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        self = .string(try c.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .bool(let b): try c.encode(b)
        }
    }

    var double: Double {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s) ?? 0
        case .bool(let b): return b ? 1 : 0
        }
    }

    var string: String {
        switch self {
        case .number(let d): return d == d.rounded() ? String(Int(d)) : String(d)
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        }
    }

    var bool: Bool {
        switch self {
        case .bool(let b): return b
        case .number(let d): return d != 0
        case .string(let s): return s == "true" || s == "1"
        }
    }
}

struct WallpaperProperty: Codable, Identifiable, Hashable {
    var key: String
    var label: String
    var kind: PropertyKind
    var value: PropertyValue
    var min: Double?
    var max: Double?
    var step: Double?
    var options: [PropertyOption]?
    var order: Int
    var id: String { key }

    init(key: String, label: String, kind: PropertyKind, value: PropertyValue,
         min: Double? = nil, max: Double? = nil, step: Double? = nil,
         options: [PropertyOption]? = nil, order: Int = 0) {
        self.key = key; self.label = label; self.kind = kind; self.value = value
        self.min = min; self.max = max; self.step = step; self.options = options; self.order = order
    }

    /// Значение в виде, пригодном для JS (как в Wallpaper Engine).
    var jsValue: Any {
        switch value {
        case .bool(let b): return b
        case .number(let d): return d
        case .string(let s):
            if kind == .combo, let d = Double(s) { return d }
            return s
        }
    }
}

extension Array where Element == WallpaperProperty {
    func value(_ key: String) -> PropertyValue? { first { $0.key == key }?.value }

    /// Объединяет новые описания свойств со старыми значениями (сохраняя то, что настроил пользователь).
    func merged(keepingValuesFrom old: [WallpaperProperty]) -> [WallpaperProperty] {
        map { p in
            var p = p
            if let o = old.first(where: { $0.key == p.key && $0.kind == p.kind }) { p.value = o.value }
            return p
        }
    }

    var jsonForJS: String {
        var dict: [String: Any] = [:]
        for p in self { dict[p.key] = ["value": p.jsValue, "type": p.kind.rawValue] }
        guard let d = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
}

// MARK: - Элемент библиотеки

struct WallpaperItem: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var type: WallpaperType
    var folder: String          // абсолютный путь к папке обоев
    var entry: String           // главный файл относительно папки (для слайдшоу — пусто)
    var preview: String? = nil  // относительный или абсолютный путь к превью
    var tags: [String] = []
    var favorite: Bool = false
    var source: WallpaperSource = .local
    var workshopID: String? = nil
    var galleryID: String? = nil
    var properties: [WallpaperProperty] = []
    var added: Date = Date()

    var folderURL: URL { URL(fileURLWithPath: folder, isDirectory: true) }
    var entryURL: URL { entry.isEmpty ? folderURL : folderURL.appendingPathComponent(entry) }
    var previewURL: URL? {
        guard let p = preview, !p.isEmpty else { return nil }
        return p.hasPrefix("/") ? URL(fileURLWithPath: p) : folderURL.appendingPathComponent(p)
    }
}

// MARK: - Плейлисты

enum PlaylistMode: String, Codable, CaseIterable { case timer, timeOfDay }

struct TimeSlot: Codable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var hour: Int
    var minute: Int
    var wallpaperID: String?
    var minutesOfDay: Int { hour * 60 + minute }
}

struct Playlist: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var items: [String] = []
    var mode: PlaylistMode = .timer
    var intervalMinutes: Double = 15
    var shuffle: Bool = false
    var slots: [TimeSlot] = []

    /// Обои, которые должны стоять сейчас в режиме «по времени суток».
    func slotWallpaper(at date: Date) -> String? {
        let valid = slots.filter { $0.wallpaperID != nil }.sorted { $0.minutesOfDay < $1.minutesOfDay }
        guard !valid.isEmpty else { return nil }
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return (valid.last { $0.minutesOfDay <= now } ?? valid.last)?.wallpaperID
    }
}

// MARK: - Настройки

struct AppSettings: Codable, Equatable {
    var fpsLimit: Int = 15
    var festiveTheme = true            // новогоднее оформление интерфейса
    var smartFPS = true                // в покое ≤ 20 кадров/с, при движении мыши и в музыке — до лимита
    var nativeScenes = true            // сцены рисуются на Metal, а не в WebKit
    var pauseOnFullscreen = true
    var pauseOnMaximized = false
    var pauseWhenCovered = true
    var pauseWhenAppFocused = false   // пауза, пока активна другая программа
    var pauseOnBattery = false
    var pauseOnLock = true
    var volume: Double = 0.5
    var muted = true
    var mouseInteraction = true
    var clickInteraction = false
    var audioReactive = false
    var launchAtLogin = false
    var spanMode = false
    var steamcmdPath = ""
    var steamUser = ""
    var steamWorkshopPath = ""
    var samplesInstalled = false
    var tosAccepted = false
    var onboardingDone = false
    var showSplash = true
    var language = "system"          // system | ru | en
    var ambientEnabled = true        // адаптация сцен к времени суток и погоде
    var weatherCity = ""             // как ввёл пользователь
    var weatherCityName = ""         // найденное название
    var weatherLat: Double = 0
    var weatherLon: Double = 0
    var calendarWidgets = false
    var nowPlayingWidgets = true
    var autoCheckUpdates = true
    var hiddenWorkshopIDs: [String] = []   // удалённые из библиотеки предметы мастерской
    // Снег поверх рабочего стола (вкладка «Снег»)
    var snowEnabled = false
    var snowDensity = 0.5
    var snowSize = 1.0
    var snowOnWindows = true            // оседает на верхних краях окон
    var snowCursor = true               // курсор отталкивает и сметает снег
    var snowGarlands = false
    // Паузы снега — отдельно от пауз обоев
    var snowPauseOnBattery = false
    var snowPauseOnFullscreen = true
    var snowPauseOnMaximized = false
    var snowPauseOnLock = true
    var snowPauseOnReduceMotion = false // «Уменьшить движение» в Универсальном доступе
    // Экран блокировки показывает стоп-кадр текущих обоев (системная картинка рабочего стола)
    var lockScreenSync = true
}

struct PersistedState: Codable {
    var assignments: [String: String] = [:]
    var spanItemID: String? = nil
    var activePlaylistID: String? = nil
    var playlists: [Playlist] = []
    var playlistIndex: Int = 0
    var lastPlaylistID: String? = nil   // последний выбранный плейлист: запускается при старте, если обои не заданы
    var userPaused = false              // «Пауза всех обоев» переживает перезапуск
}

enum SidebarItem: String, Hashable, CaseIterable {
    case library, gallery, playlists, workshop, editor, snow, settings

    var title: String {
        switch self {
        case .library: return tr("Библиотека")
        case .gallery: return tr("Галерея")
        case .playlists: return tr("Плейлисты")
        case .workshop: return tr("Мастерская")
        case .editor: return tr("Редактор сцен")
        case .snow: return tr("Снег")
        case .settings: return tr("Настройки")
        }
    }

    var icon: String {
        switch self {
        case .library: return "square.grid.2x2.fill"
        case .gallery: return "sparkles.rectangle.stack.fill"
        case .playlists: return "play.square.stack.fill"
        case .workshop: return "arrow.down.circle.fill"
        case .editor: return "square.3.layers.3d"
        case .snow: return "snowflake"
        case .settings: return "gearshape.fill"
        }
    }
}

enum AppOverlay: String, Identifiable {
    case onboarding, credits, tos
    var id: String { rawValue }
}

// MARK: - Встроенные свойства для разных типов

enum DefaultProps {
    static func fill(order: Int = 0) -> WallpaperProperty {
        WallpaperProperty(key: "fill", label: tr("Масштаб"), kind: .combo, value: .string("fill"),
                          options: [PropertyOption(label: tr("Заполнить"), value: "fill"),
                                    PropertyOption(label: tr("Вписать"), value: "fit"),
                                    PropertyOption(label: tr("Растянуть"), value: "stretch")],
                          order: order)
    }

    static func slider(_ key: String, _ label: String, _ v: Double, _ lo: Double, _ hi: Double,
                       step: Double? = nil, order: Int) -> WallpaperProperty {
        WallpaperProperty(key: key, label: label, kind: .slider, value: .number(v), min: lo, max: hi, step: step, order: order)
    }

    static func forType(_ t: WallpaperType) -> [WallpaperProperty] {
        switch t {
        case .video:
            return [fill(order: 0), slider("rate", tr("Скорость воспроизведения"), 1, 0.25, 2, order: 1)]
        case .image:
            return [fill(order: 0)]
        case .slideshow:
            return [fill(order: 0),
                    slider("interval", tr("Интервал (сек)"), 30, 3, 600, step: 1, order: 1),
                    slider("transition", tr("Длительность перехода (сек)"), 1.5, 0, 5, order: 2),
                    WallpaperProperty(key: "shuffle", label: tr("Случайный порядок"), kind: .bool, value: .bool(false), order: 3)]
        case .shader:
            return [slider("speed", tr("Скорость"), 1, 0, 3, order: -2),
                    slider("quality", tr("Качество (разрешение)"), 1, 0.25, 2, order: -1)]
        case .scene:
            return [slider("parallax", tr("Сила параллакса"), 1, 0, 3, order: 0),
                    slider("speed", tr("Скорость анимации"), 1, 0, 3, order: 1),
                    slider("quality", tr("Качество (разрешение)"), 1, 0.5, 2, order: 2)]
        case .web:
            return []
        }
    }
}
