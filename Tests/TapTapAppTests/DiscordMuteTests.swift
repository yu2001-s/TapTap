import AppKit
import Testing
@testable import TapTapApp

@Test func discordMuteMatchesOnlyTheMicrophoneSwitchInSupportedLanguages() {
    for label in ["Mute", "Unmute", "靜音", "解除靜音", "静音", "取消静音"] {
        #expect(DiscordMute.isMuteSwitch(role: "AXCheckBox", label: label, value: 0))
        #expect(DiscordMute.isMuteSwitch(role: "AXSwitch", label: label, value: 1))
    }
    for label in ["Deafen", "拒聽", "Mute Channel", "已靜音 直播", "Mute Notifications"] {
        #expect(!DiscordMute.isMuteSwitch(role: "AXCheckBox", label: label, value: 1))
    }
    #expect(!DiscordMute.isMuteSwitch(role: "AXButton", label: "Mute", value: 0))
    #expect(!DiscordMute.isMuteSwitch(role: "AXCheckBox", label: "Mute", value: nil))
    #expect(!DiscordMute.isMuteSwitch(role: "AXCheckBox", label: "Mute", value: 2))
}

@Test func aDiscordActionKeepsTheSavedKeyboardShortcutAndOtherGestures() throws {
    var config = AppConfig()
    var action = GestureAction(kind: .keyboard, keyCode: 46,
        modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, keyLabel: "M")
    action.keyboardAppPath = "/Applications/Discord.app"
    action.kind = .discordMute
    config.actions[.rightTriple] = action
    let restored = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
    #expect(restored == config)
    #expect(restored.action(.rightTriple).needsAccessibility)
    #expect(restored.action(.rightTriple).keyCode == 46)
    #expect(restored.action(.leftDouble).kind == .media)
}
