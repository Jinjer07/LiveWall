import Foundation

/// Локализация интерфейса. Ключ — русская строка; перевод берётся из таблицы `LocEN.table`.
/// Язык переключается на лету (Настройки → Язык), без перезапуска.
enum Loc {
    nonisolated(unsafe) static var lang: String = "ru"

    static func resolve(_ setting: String) -> String {
        switch setting {
        case "ru", "en": return setting
        default:
            return (Locale.preferredLanguages.first ?? "en").hasPrefix("ru") ? "ru" : "en"
        }
    }

    static var isEnglish: Bool { lang == "en" }
    static var localeID: String { isEnglish ? "en-US" : "ru-RU" }

    static let table: [String: String] = {
        var d: [String: String] = [:]
        for line in LocEN.table.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.components(separatedBy: " ||| ")
            guard parts.count == 2 else { continue }
            d[parts[0].replacingOccurrences(of: "\\n", with: "\n")] = parts[1].replacingOccurrences(of: "\\n", with: "\n")
        }
        return d
    }()
}

/// Перевод строки. `%@` в ключе заменяются аргументами по порядку.
func tr(_ key: String, _ args: Any...) -> String {
    var s = Loc.isEnglish ? (Loc.table[key] ?? key) : key
    for a in args {
        guard let r = s.range(of: "%@") else { break }
        s.replaceSubrange(r, with: String(describing: a))
    }
    return s
}
