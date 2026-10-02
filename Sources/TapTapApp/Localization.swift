import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: L10n.text("System Default")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        }
    }
}

enum L10n {
    static let languageKey = "appLanguage"

    // SwiftPM's generated accessor expects a bundle beside the executable.
    // A packaged macOS app stores it in Contents/Resources instead.
    static let resources: Bundle = {
        if let url = Bundle.main.url(forResource: "TapTap_TapTapApp", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()

    static var language: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: languageKey) ?? "") ?? .system
    }

    static func text(_ key: String, language: AppLanguage? = nil) -> String {
        let selected = language ?? self.language
        let code = selected == .system ? (resources.preferredLocalizations.first ?? "en") : selected.rawValue
        let bundle = resources.url(forResource: code, withExtension: "lproj").flatMap(Bundle.init(url:)) ?? resources
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }
}
