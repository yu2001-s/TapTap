import AppKit

enum ShortcutKeyGroup: String, CaseIterable, Identifiable {
    case letters = "Letters", numbers = "Numbers", punctuation = "Symbols"
    case navigation = "Navigation & Editing", function = "Function Keys", keypad = "Numeric Keypad", other = "Other Keys"
    var id: String { rawValue }
    var title: String { L10n.text(rawValue) }
    var keys: [ShortcutKey] { ShortcutKey.all.filter { $0.group == self } }
}

struct ShortcutKey: Identifiable {
    let code: UInt16
    let labelKey: String
    var label: String { L10n.text(labelKey) }
    let group: ShortcutKeyGroup
    var id: UInt16 { code }

    static let all: [ShortcutKey] = {
        func keys(_ group: ShortcutKeyGroup, _ values: [(UInt16, String)]) -> [ShortcutKey] {
            values.map { ShortcutKey(code: $0.0, labelKey: $0.1, group: group) }
        }
        return keys(.letters, [
            (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"),
            (4, "H"), (34, "I"), (38, "J"), (40, "K"), (37, "L"), (46, "M"), (45, "N"),
            (31, "O"), (35, "P"), (12, "Q"), (15, "R"), (1, "S"), (17, "T"), (32, "U"),
            (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z"),
        ]) + keys(.numbers, [
            (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"),
            (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9"),
        ]) + keys(.punctuation, [
            (50, "`"), (27, "−"), (24, "="), (33, "["), (30, "]"), (42, "\\"),
            (41, ";"), (39, "'"), (43, ","), (47, "."), (44, "/"), (10, "§ (ISO)"),
        ]) + keys(.navigation, [
            (49, "Space"), (36, "↩ Return"), (48, "⇥ Tab"), (53, "Esc"),
            (51, "⌫ Delete"), (117, "⌦ Forward Delete"), (123, "←"), (124, "→"),
            (125, "↓"), (126, "↑"), (115, "Home"), (119, "End"), (116, "Page Up"), (121, "Page Down"),
        ]) + keys(.function, [
            (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"), (97, "F6"),
            (98, "F7"), (100, "F8"), (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12"),
            (105, "F13"), (107, "F14"), (113, "F15"), (106, "F16"), (64, "F17"), (79, "F18"),
            (80, "F19"), (90, "F20"),
        ]) + keys(.keypad, [
            (82, "Keypad 0"), (83, "Keypad 1"), (84, "Keypad 2"), (85, "Keypad 3"),
            (86, "Keypad 4"), (87, "Keypad 5"), (88, "Keypad 6"), (89, "Keypad 7"),
            (91, "Keypad 8"), (92, "Keypad 9"), (65, "Keypad ."), (67, "Keypad ×"),
            (69, "Keypad +"), (75, "Keypad ÷"), (78, "Keypad −"), (81, "Keypad ="),
            (71, "Clear"), (76, "Keypad Enter"), (95, "Keypad , (JIS)"),
        ]) + keys(.other, [
            (114, "Help"), (93, "¥ (JIS)"), (94, "_ (JIS)"), (102, "Eisu (JIS)"), (104, "Kana (JIS)"),
        ])
    }()

    static func find(_ code: UInt16) -> ShortcutKey? { all.first { $0.code == code } }
    static func label(_ code: UInt16) -> String { find(code)?.label ?? L10n.format("Key %d", Int(code)) }
}

struct RecordedShortcut {
    let keyCode: UInt16
    let modifiers: UInt
    var label: String { ShortcutKey.label(keyCode) }

    static let allowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

    static func modifiers(from flags: NSEvent.ModifierFlags, fnPressed: Bool) -> NSEvent.ModifierFlags {
        // macOS also sets .function on arrows and F keys. Only include Fn when
        // the physical modifier is held; otherwise recording ↑ would become fn↑.
        var result = flags.intersection(allowedModifiers)
        result.remove(.function)
        if fnPressed { result.insert(.function) }
        return result
    }

    var isRecordingCancel: Bool { keyCode == 53 && modifiers == 0 }

    static func eventFlags(keyCode: UInt16, modifiers: UInt) -> CGEventFlags {
        let f = NSEvent.ModifierFlags(rawValue: modifiers)
        var flags = CGEventFlags()
        if f.contains(.command) { flags.insert(.maskCommand) }
        if f.contains(.option) { flags.insert(.maskAlternate) }
        if f.contains(.control) { flags.insert(.maskControl) }
        if f.contains(.shift) { flags.insert(.maskShift) }
        if f.contains(.function) { flags.insert(.maskSecondaryFn) }
        if ShortcutKey.find(keyCode)?.group == .keypad { flags.insert(.maskNumericPad) }
        return flags
    }
}
