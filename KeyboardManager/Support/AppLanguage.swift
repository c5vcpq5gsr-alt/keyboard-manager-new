import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case german = "de"
    case english = "en"

    static let preferenceKey = "preferredLanguage"

    var id: String { rawValue }

    var locale: Locale {
        Locale(identifier: self == .english ? "en_GB" : "de_DE")
    }

    static var current: AppLanguage {
        normalized(UserDefaults.standard.string(forKey: preferenceKey))
    }

    static func normalized(_ value: String?) -> AppLanguage {
        value == AppLanguage.english.rawValue ? .english : .german
    }
}

enum L10n {
    static func text(
        _ key: String,
        language: String? = nil,
        arguments: CVarArg...
    ) -> String {
        let selected = language.map(AppLanguage.normalized) ?? AppLanguage.current
        let format: String
        if selected == .german {
            // German is the catalog's source language, so no de.lproj is
            // required and the key itself is the authoritative source text.
            format = key
        } else {
            let languageBundle = Bundle.main.path(
                forResource: selected.rawValue,
                ofType: "lproj"
            ).flatMap(Bundle.init(path:))
            format = (languageBundle ?? .main).localizedString(
                forKey: key,
                value: key,
                table: nil
            )
        }
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: selected.locale, arguments: arguments)
    }
}
