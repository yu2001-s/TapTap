import AppKit
import Testing
@testable import TapTapApp

@Test func recordingAnArrowDoesNotAddAnUnpressedFnModifier() {
    // AppKit reports these extra flags for an arrow key, even without physical Fn.
    let flags: NSEvent.ModifierFlags = [.control, .function, .numericPad]
    let recorded = RecordedShortcut.modifiers(from: flags, fnPressed: false)
    #expect(recorded == .control)
    let posted = RecordedShortcut.eventFlags(keyCode: 123, modifiers: recorded.rawValue)
    #expect(posted == .maskControl)
}

@Test func fnAndKeypadModifiersReachThePostedKeyboardEvent() {
    let recorded = RecordedShortcut.modifiers(from: [.command, .capsLock], fnPressed: true)
    let flags = RecordedShortcut.eventFlags(keyCode: 76, modifiers: recorded.rawValue)
    #expect(flags.contains(.maskCommand))
    #expect(flags.contains(.maskSecondaryFn))
    #expect(flags.contains(.maskNumericPad))
    #expect(!flags.contains(.maskAlphaShift))
    #expect(GestureAction.shortcutString(keyLabel: "F20", modifiers: recorded.rawValue) == "fn ⌘F20")
}

@Test func escapeCombinationsCanBeRecordedWhilePlainEscapeCancels() {
    #expect(RecordedShortcut(keyCode: 53, modifiers: 0).isRecordingCancel)
    #expect(!RecordedShortcut(keyCode: 53, modifiers: NSEvent.ModifierFlags.command.rawValue).isRecordingCancel)
}
