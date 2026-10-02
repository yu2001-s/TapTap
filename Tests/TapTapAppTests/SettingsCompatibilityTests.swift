import Foundation
import Testing
@testable import TapTapApp

@Test func oldSettingsKeepCustomActionsWhenIconPreferenceIsAdded() throws {
    // The exact pre-update format: enum-keyed dictionaries encode as alternating
    // keys and values, and there is no showMenuBarIcon field.
    let legacy = Data("""
    {
      "enabled": false,
      "showHUD": false,
      "minPeak": 13,
      "actions": ["mac_left×2", {
        "kind": "keyboard", "media": "playPause", "keyCode": 105,
        "modifiers": 1310720, "keyLabel": "F13", "appPath": "",
        "shortcutName": "", "command": ""
      }, "mac_right×3", {
        "kind": "shell", "media": "playPause", "modifiers": 0,
        "keyLabel": "", "appPath": "", "shortcutName": "", "command": "echo test"
      }]
    }
    """.utf8)
    let config = try JSONDecoder().decode(AppConfig.self, from: legacy)
    #expect(config.showMenuBarIcon)
    #expect(!config.enabled)
    #expect(!config.showHUD)
    #expect(config.minPeak == 13)
    #expect(config.action(.leftDouble).keyCode == 105)
    #expect(config.action(.leftDouble).modifiers == 1310720)
    #expect(config.action(.rightTriple).command == "echo test")

    let restored = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
    #expect(restored == config)
}

@Test func hidingTheIconPersistsWithoutDisablingDetection() throws {
    var config = AppConfig()
    config.showMenuBarIcon = false
    let restored = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
    #expect(!restored.showMenuBarIcon)
    #expect(restored.enabled)
    #expect(restored.action(.leftDouble).kind == .media)
    #expect(restored.action(.rightDouble).media == .next)
}
