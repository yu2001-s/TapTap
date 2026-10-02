import Foundation
import Testing
@testable import TapTapApp

@Test func allLanguagesHaveTheSameStringsAndFormatArguments() throws {
    var translations: [[String: String]] = []
    for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese] {
        let directory = try #require(L10n.localizationBundle(for: language.rawValue, in: L10n.resources)?.bundleURL)
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

@Test func lowercaseSwiftPMResourcesSupportChineseScriptIdentifiers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("bundle")
    defer { try? FileManager.default.removeItem(at: root) }
    let locale = root.appendingPathComponent("zh-hans.lproj")
    try FileManager.default.createDirectory(at: locale, withIntermediateDirectories: true)
    let plist = ["CFBundleIdentifier": "app.taptap.localization-test", "CFBundleDevelopmentRegion": "en"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: root.appendingPathComponent("Info.plist"))
    try "\"Settings…\" = \"设置…\";".write(to: locale.appendingPathComponent("Localizable.strings"),
                                        atomically: true, encoding: .utf8)
    let resources = try #require(Bundle(url: root))
    let selected = try #require(L10n.localizationBundle(for: "zh-Hans", in: resources))
    #expect(selected.localizedString(forKey: "Settings…", value: nil, table: nil) == "设置…")
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
