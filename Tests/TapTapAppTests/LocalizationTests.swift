import Foundation
import Testing
@testable import TapTapApp

@Test func allLanguagesHaveTheSameStringsAndFormatArguments() throws {
    var translations: [[String: String]] = []
    for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese] {
        let directory = try #require(L10n.resources.url(forResource: language.rawValue, withExtension: "lproj"))
        let data = try Data(contentsOf: directory.appendingPathComponent("Localizable.strings"))
        let values = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        translations.append(values)
    }
    let reference = translations[0]
    let pattern = try NSRegularExpression(pattern: "%[0-9$]*[@dfsu]")
    func arguments(_ string: String) -> [String] {
        let ns = string as NSString
        return pattern.matches(in: string, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }
    for values in translations {
        #expect(Set(values.keys) == Set(reference.keys))
        for (key, value) in values {
            #expect(!value.isEmpty)
            #expect(arguments(value) == arguments(key))
        }
    }
}

@Test func theSelectedLanguageUsesItsOwnResourceBundle() {
    #expect(L10n.text("Settings…", language: .english) == "Settings…")
    #expect(L10n.text("Settings…", language: .simplifiedChinese) == "设置…")
    #expect(L10n.text("Settings…", language: .traditionalChinese) == "設定…")
    #expect(L10n.text("Accessibility Permission Required", language: .english) == "Accessibility Permission Required")
    #expect(L10n.text("Keypad Enter", language: .simplifiedChinese) == "小键盘 Enter")
}

@Test func localizationDoesNotChangeStoredGestureIdentifiers() {
    #expect(GestureSlot.rightTriple.rawValue == "mac_right×3")
    #expect(GestureAction.Kind.keyboard.rawValue == "keyboard")
    #expect(MediaKey.playPause.rawValue == "playPause")
}
