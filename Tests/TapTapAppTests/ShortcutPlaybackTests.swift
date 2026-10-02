import AppKit
import Testing
@testable import TapTapApp

@Test func globalShortcutIncludesModifierPressesAndReleases() throws {
    let modifiers: NSEvent.ModifierFlags = [.control, .command]
    let steps = ShortcutPlayback.steps(keyCode: 46, modifiers: modifiers.rawValue)
    #expect(steps.map(\.keyCode) == [59, 55, 46, 46, 55, 59])
    #expect(steps.map(\.type) == [.flagsChanged, .flagsChanged, .keyDown, .keyUp, .flagsChanged, .flagsChanged])
    #expect(steps.map(\.isDown) == [true, true, true, false, false, false])
    #expect(steps[0].flags.contains(.maskControl))
    #expect(!steps[0].flags.contains(.maskCommand))
    #expect(steps[2].flags.contains([.maskControl, .maskCommand]))
    #expect(steps[2].flags.rawValue & 0x09 == 0x09)
    #expect(steps[2].delayAfter >= 0.05)
    #expect(!steps[4].flags.contains(.maskCommand))
    #expect(steps[4].flags.contains(.maskControl))
    #expect(steps[5].flags.isEmpty)

    let source = try #require(CGEventSource(stateID: .privateState))
    for step in steps {
        let event = try #require(step.event(source: source))
        #expect(event.type == step.type)
        #expect(event.flags == step.flags)
        #expect(event.getIntegerValueField(.keyboardEventKeycode) == Int64(step.keyCode))
    }
}

@Test func playbackDoesNotReleaseAControlKeyHeldByTheUser() {
    let held = CGEventFlags.maskControl.union(CGEventFlags(rawValue: 0x2000)) // right Control
    let steps = ShortcutPlayback.steps(keyCode: 46,
        modifiers: NSEvent.ModifierFlags([.control, .command]).rawValue, heldFlags: held)
    #expect(steps.map(\.keyCode) == [55, 46, 46, 55])
    #expect(steps.last?.flags == held)
}

@Test func aSingleKeyStillHasAMatchingReleaseAndKeypadFlagsStayOnTheKey() {
    let steps = ShortcutPlayback.steps(keyCode: 82, modifiers: NSEvent.ModifierFlags.option.rawValue)
    #expect(steps.map(\.keyCode) == [58, 82, 82, 58])
    #expect(steps[1].flags.contains(.maskNumericPad))
    #expect(steps[2].flags.contains(.maskNumericPad))
    #expect(!steps[0].flags.contains(.maskNumericPad))
    #expect(steps.last?.flags.isEmpty == true)
    let single = ShortcutPlayback.steps(keyCode: 0, modifiers: 0)
    #expect(single.map(\.type) == [.keyDown, .keyUp])
    #expect(single.allSatisfy { $0.flags.isEmpty })
}

@Test func theKeyboardTargetAppIsSavedWithoutChangingOtherActions() throws {
    var config = AppConfig()
    var action = GestureAction(kind: .keyboard, keyCode: 46,
        modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, keyLabel: "M")
    action.keyboardAppPath = "/Applications/Discord.app"
    config.actions[.rightTriple] = action
    let loaded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
    #expect(loaded == config)
    #expect(loaded.action(.rightTriple).keyboardAppPath == "/Applications/Discord.app")
    #expect(loaded.action(.leftDouble).keyboardAppPath == nil)
}

@Test @MainActor func aMissingTargetReportsAnErrorInsteadOfTypingIntoTheCurrentApp() {
    var action = GestureAction(kind: .keyboard, keyCode: 46, keyLabel: "M")
    action.keyboardAppPath = "/TapTap-Unavailable-Test-App.app"
    #expect(ActionRunner.run(action) == L10n.format("Open %@ first", "TapTap-Unavailable-Test-App"))
}
