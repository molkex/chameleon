import Foundation

/// Shared Russian noun declension helpers used across views.
enum StringUtils {
    /// "день" / "дня" / "дней" for a given count.
    static func dayNoun(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        if mod100 >= 11 && mod100 <= 19 { return "дней" }
        if mod10 == 1 { return "день" }
        if mod10 >= 2 && mod10 <= 4 { return "дня" }
        return "дней"
    }

    /// "сервер" / "сервера" / "серверов" for a given count.
    static func serverNoun(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        if mod100 >= 11 && mod100 <= 19 { return "серверов" }
        if mod10 == 1 { return "сервер" }
        if mod10 >= 2 && mod10 <= 4 { return "сервера" }
        return "серверов"
    }
}
