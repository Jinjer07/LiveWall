import Foundation

/// Документ сцены (scene.json). Рендерится рантаймом scene.html (WebGL2).
struct SceneDoc: Codable, Equatable {
    var version: Int = 1
    var width: Double = 1920
    var height: Double = 1080
    var background: String = "#000000"
    var ambient: Bool? = nil          // адаптация к времени суток и погоде
    var ambientPrecip: Bool? = nil    // осадки по погоде
    var layers: [SceneLayer] = []
}

struct SceneLayer: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case image, particles, text, color
        var title: String {
            switch self {
            case .image: return tr("Изображение")
            case .particles: return tr("Частицы")
            case .text: return tr("Текст")
            case .color: return tr("Заливка")
            }
        }
        var symbol: String {
            switch self {
            case .image: return "photo"
            case .particles: return "snowflake"
            case .text: return "textformat"
            case .color: return "paintbrush"
            }
        }
    }

    var id: String = UUID().uuidString
    var name: String
    var kind: Kind
    var visible: Bool = true
    var file: String? = nil

    // Трансформация (x, y — центр в долях сцены 0…1)
    var x: Double = 0.5
    var y: Double = 0.5
    var scale: Double = 1
    var rotation: Double = 0
    var rotationSpeed: Double = 0
    var opacity: Double = 1
    var parallax: Double = 0
    var blend: String = "normal"
    var tint: String = "#ffffff"
    var feather: Double? = nil      // мягкость краёв 0…0.5

    // Цветокоррекция
    var hue: Double = 0
    var saturation: Double = 1
    var brightness: Double = 1

    // Эффект волн
    var waveEnabled: Bool = false
    var waveAmplitude: Double = 0.5
    var waveFrequency: Double = 2
    var waveSpeed: Double = 1
    var waveVertical: Bool = false

    // Свечение
    var glowEnabled: Bool = false
    var glowRadius: Double = 4
    var glowIntensity: Double = 0.6
    var glowColor: String = "#ffffff"

    // Реакция на звук
    var audioPulse: Double = 0
    var audioBand: String = "bass"

    // Частицы
    var pCount: Int = 150
    var pEmitter: String = "top"
    var pSizeMin: Double = 2
    var pSizeMax: Double = 6
    var pSpeed: Double = 60
    var pDirection: Double = 90
    var pSpread: Double = 20
    var pLifetime: Double = 20
    var pGravity: Double = 0
    var pWobble: Double = 10
    var pColor: String = "#ffffff"
    var pColor2: String = "#cfe3ff"
    var pShape: String = "soft"
    var pMouseRepel: Bool = false
    var pAudio: Double = 0

    // Текст
    var text: String = "{time}"
    var fontSize: Double = 160
    var fontWeight: String = "600"
    var textColor: String = "#ffffff"

    // Заливка
    var width: Double = 1920
    var height: Double = 1080
}

enum ParticlePreset: String, CaseIterable, Identifiable {
    case snow, rain, sparks, dust, fireflies, bubbles
    var id: String { rawValue }
    var title: String {
        switch self {
        case .snow: return tr("Снег")
        case .rain: return tr("Дождь")
        case .sparks: return tr("Искры")
        case .dust: return tr("Пыль")
        case .fireflies: return tr("Светлячки")
        case .bubbles: return tr("Пузыри")
        }
    }

    func make() -> SceneLayer {
        var l = SceneLayer(name: title, kind: .particles)
        switch self {
        case .snow:
            l.pEmitter = "top"; l.pCount = 260; l.pSizeMin = 2; l.pSizeMax = 7; l.pSpeed = 45
            l.pDirection = 90; l.pSpread = 15; l.pWobble = 22; l.pLifetime = 40; l.parallax = 0.4
        case .rain:
            l.pEmitter = "top"; l.pCount = 500; l.pSizeMin = 10; l.pSizeMax = 22; l.pSpeed = 1100
            l.pDirection = 95; l.pSpread = 2; l.pWobble = 0; l.pLifetime = 3; l.pShape = "streak"
            l.pColor = "#a9c7ff"; l.pColor2 = "#d8e6ff"; l.opacity = 0.6
        case .sparks:
            l.pEmitter = "bottom"; l.pCount = 140; l.pSizeMin = 2; l.pSizeMax = 6; l.pSpeed = 90
            l.pDirection = 270; l.pSpread = 25; l.pWobble = 18; l.pLifetime = 9; l.blend = "add"
            l.pColor = "#ffb347"; l.pColor2 = "#ff4a1c"; l.pAudio = 0.6
        case .dust:
            l.pEmitter = "full"; l.pCount = 160; l.pSizeMin = 1; l.pSizeMax = 3.5; l.pSpeed = 8
            l.pDirection = 0; l.pSpread = 180; l.pWobble = 6; l.pLifetime = 12; l.opacity = 0.55; l.parallax = 0.6
        case .fireflies:
            l.pEmitter = "full"; l.pCount = 70; l.pSizeMin = 4; l.pSizeMax = 10; l.pSpeed = 14
            l.pDirection = 0; l.pSpread = 180; l.pWobble = 30; l.pLifetime = 7; l.blend = "add"
            l.pColor = "#d8ff6b"; l.pColor2 = "#7dffb0"; l.pMouseRepel = true
        case .bubbles:
            l.pEmitter = "bottom"; l.pCount = 60; l.pSizeMin = 8; l.pSizeMax = 30; l.pSpeed = 50
            l.pDirection = 270; l.pSpread = 10; l.pWobble = 25; l.pLifetime = 25; l.pShape = "circle"
            l.opacity = 0.35; l.pColor = "#bfe9ff"; l.pColor2 = "#ffffff"; l.pMouseRepel = true
        }
        return l
    }
}

/// Готовые текстовые виджеты для сцен.
enum WidgetPreset: String, CaseIterable, Identifiable {
    case clock, date, system, battery, music, calendar, weather
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clock: return tr("Часы")
        case .date: return tr("Дата")
        case .system: return tr("Системный монитор")
        case .battery: return tr("Батарея")
        case .music: return tr("Сейчас играет")
        case .calendar: return tr("Ближайшее событие")
        case .weather: return tr("Погода")
        }
    }
    var text: String {
        switch self {
        case .clock: return "{time}"
        case .date: return "{weekday}, {date}"
        case .system: return "CPU {cpu}   RAM {ram}"
        case .battery: return "{charging} {battery}"
        case .music: return "♪ {track}\n{artist}"
        case .calendar: return "{eventTime}  {event}"
        case .weather: return "{temp}  {weather}\n{city}"
        }
    }
    var fontSize: Double {
        switch self {
        case .clock: return 200
        case .date: return 48
        default: return 34
        }
    }
    var weight: String { self == .clock ? "200" : "500" }
    var position: (Double, Double) {
        switch self {
        case .clock: return (0.5, 0.42)
        case .date: return (0.5, 0.56)
        case .system: return (0.14, 0.92)
        case .battery: return (0.92, 0.08)
        case .music: return (0.86, 0.9)
        case .calendar: return (0.14, 0.08)
        case .weather: return (0.86, 0.1)
        }
    }
}
