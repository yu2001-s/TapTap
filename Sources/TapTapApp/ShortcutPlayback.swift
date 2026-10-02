import AppKit
import ApplicationServices

/// A complete keystroke, including the modifier transitions observed by global
/// hotkey listeners. A flag on the main key alone does not press Control/Command.
enum ShortcutPlayback {
    struct Step {
        let keyCode: CGKeyCode
        let type: CGEventType
        let isDown: Bool
        let flags: CGEventFlags
        let delayAfter: TimeInterval

        func event(source: CGEventSource) -> CGEvent? {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode,
                                      keyDown: isDown) else { return nil }
            event.type = type
            event.flags = flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            return event
        }
    }

    private struct ModifierKey {
        let code: CGKeyCode
        let flag: CGEventFlags
        let deviceFlag: CGEventFlags
    }

    // The device flags identify the left modifier keys, as in IOLLEvent.h.
    // Some global listeners distinguish these from the aggregate modifier flags.
    private static let modifierKeys: [ModifierKey] = [
        .init(code: 59, flag: .maskControl, deviceFlag: .init(rawValue: 0x01)),
        .init(code: 58, flag: .maskAlternate, deviceFlag: .init(rawValue: 0x20)),
        .init(code: 56, flag: .maskShift, deviceFlag: .init(rawValue: 0x02)),
        .init(code: 55, flag: .maskCommand, deviceFlag: .init(rawValue: 0x08)),
        .init(code: 63, flag: .maskSecondaryFn, deviceFlag: []),
    ]
    private static let queue = DispatchQueue(label: "app.taptap.shortcut-playback")

    static func steps(keyCode: CGKeyCode, modifiers: UInt, heldFlags: CGEventFlags = []) -> [Step] {
        let requested = RecordedShortcut.eventFlags(keyCode: keyCode, modifiers: modifiers)
        let pressed = modifierKeys.filter { requested.contains($0.flag) && !heldFlags.contains($0.flag) }
        var flags = heldFlags
        var result: [Step] = []
        for key in pressed {
            flags.formUnion([key.flag, key.deviceFlag])
            result.append(Step(keyCode: key.code, type: .flagsChanged, isDown: true, flags: flags, delayAfter: 0.015))
        }
        let keyFlags = flags.union(requested)
        // Leave the key down long enough for apps that sample keyboard state.
        result.append(Step(keyCode: keyCode, type: .keyDown, isDown: true, flags: keyFlags, delayAfter: 0.07))
        result.append(Step(keyCode: keyCode, type: .keyUp, isDown: false, flags: keyFlags, delayAfter: 0.015))
        for key in pressed.reversed() {
            flags.subtract([key.flag, key.deviceFlag])
            result.append(Step(keyCode: key.code, type: .flagsChanged, isDown: false, flags: flags, delayAfter: 0.015))
        }
        return result
    }

    static func send(keyCode: CGKeyCode, modifiers: UInt, targetPID: pid_t? = nil) {
        queue.async {
            guard Accessibility.isTrusted, let source = CGEventSource(stateID: .hidSystemState) else { return }
            let keyboardFlags: CGEventFlags = [.maskControl, .maskCommand, .maskAlternate, .maskShift,
                                               .maskSecondaryFn, .maskAlphaShift]
            // App-directed events do not share the physical keyboard's held
            // modifiers. Include the full configured combination for the target.
            let held: CGEventFlags = targetPID == nil ? CGEventSource.flagsState(.hidSystemState)
                .intersection(keyboardFlags.union(CGEventFlags(rawValue: 0x207F))) : []
            let sequence = steps(keyCode: keyCode, modifiers: modifiers, heldFlags: held)
            // Construct every event before posting any, so a failed allocation
            // cannot leave a modifier down without its matching release.
            let events = sequence.compactMap { $0.event(source: source) }
            guard events.count == sequence.count else { return }
            for (event, step) in zip(events, sequence) {
                event.timestamp = DispatchTime.now().uptimeNanoseconds
                if let targetPID { event.postToPid(targetPID) }
                else { event.post(tap: .cghidEventTap) }
                Thread.sleep(forTimeInterval: step.delayAfter)
            }
        }
    }
}
