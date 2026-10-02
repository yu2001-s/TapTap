import AppKit
import ApplicationServices

enum GestureSlot: String, CaseIterable, Codable, Identifiable {
    case leftDouble = "mac_left×2"
    case leftTriple = "mac_left×3"
    case rightDouble = "mac_right×2"
    case rightTriple = "mac_right×3"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftDouble: L10n.text("Left Double Tap")
        case .leftTriple: L10n.text("Left Triple Tap")
        case .rightDouble: L10n.text("Right Double Tap")
        case .rightTriple: L10n.text("Right Triple Tap")
        }
    }

    var symbol: String {
        switch self {
        case .leftDouble, .leftTriple: "hand.point.left"
        case .rightDouble, .rightTriple: "hand.point.right"
        }
    }
}

enum MediaKey: String, CaseIterable, Codable {
    case playPause, next, previous, volumeUp, volumeDown, mute

    var title: String {
        switch self {
        case .playPause: L10n.text("Play / Pause")
        case .next: L10n.text("Next Track")
        case .previous: L10n.text("Previous Track")
        case .volumeUp: L10n.text("Volume Up")
        case .volumeDown: L10n.text("Volume Down")
        case .mute: L10n.text("Mute")
        }
    }

    /// NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h
    var nxKeyType: Int {
        switch self {
        case .playPause: 16
        case .next: 17
        case .previous: 18
        case .volumeUp: 0
        case .volumeDown: 1
        case .mute: 7
        }
    }
}

struct GestureAction: Codable, Equatable {
    enum Kind: String, CaseIterable, Codable {
        case none, media, keyboard, openApp, shortcut, shell

        var title: String {
            switch self {
            case .none: L10n.text("None")
            case .media: L10n.text("Media Key")
            case .keyboard: L10n.text("Keyboard Shortcut")
            case .openApp: L10n.text("Open App")
            case .shortcut: L10n.text("Run Shortcut")
            case .shell: L10n.text("Shell Command")
            }
        }
    }

    var kind: Kind = .none
    var media: MediaKey = .playPause
    var keyCode: UInt16?
    var modifiers: UInt = 0                 // NSEvent.ModifierFlags raw value
    var keyLabel: String = ""
    var keyboardAppPath: String?
    var appPath: String = ""
    var shortcutName: String = ""
    var command: String = ""

    var needsAccessibility: Bool { kind == .media || kind == .keyboard }

    var summary: String {
        switch kind {
        case .none: L10n.text("None")
        case .media: media.title
        case .keyboard:
            if let keyCode { Self.shortcutString(keyLabel: ShortcutKey.label(keyCode), modifiers: modifiers)
                + (keyboardAppPath.map { " → " + Self.appName($0) } ?? "") }
            else { L10n.text("Shortcut Not Set") }
        case .openApp: appPath.isEmpty ? L10n.text("No App Selected") : L10n.format("Open %@", Self.appName(appPath))
        case .shortcut: shortcutName.isEmpty ? L10n.text("No Shortcut Selected") : L10n.format("Run Shortcut “%@”", shortcutName)
        case .shell: command.isEmpty ? L10n.text("Command Not Set") : command
        }
    }

    static func shortcutString(keyLabel: String, modifiers: UInt) -> String {
        let f = NSEvent.ModifierFlags(rawValue: modifiers)
        var s = ""
        if f.contains(.function) { s += "fn " }
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s + keyLabel
    }

    static func appName(_ path: String) -> String {
        FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
    }
}

enum ActionRunner {
    @discardableResult static func run(_ a: GestureAction) -> String? {
        switch a.kind {
        case .none:
            break
        case .media:
            postMediaKey(a.media.nxKeyType)
        case .keyboard:
            guard let code = a.keyCode else { return L10n.text("Shortcut Not Set") }
            var targetPID: pid_t?
            if let path = a.keyboardAppPath, !path.isEmpty {
                guard let target = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path
                }) else { return L10n.format("Open %@ first", GestureAction.appName(path)) }
                targetPID = target.processIdentifier
            }
            ShortcutPlayback.send(keyCode: code, modifiers: a.modifiers, targetPID: targetPID)
        case .openApp:
            guard !a.appPath.isEmpty else { return nil }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: a.appPath), configuration: .init())
        case .shortcut:
            guard !a.shortcutName.isEmpty else { return nil }
            launch("/usr/bin/shortcuts", ["run", a.shortcutName])
        case .shell:
            guard !a.command.isEmpty else { return nil }
            launch("/bin/zsh", ["-lc", a.command])
        }
        return nil
    }

    private static func launch(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }

    private static func postMediaKey(_ key: Int) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = (key << 16) | ((down ? 0xA : 0xB) << 8)
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                        windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Names from the Shortcuts app, for the picker.
    static func listShortcuts() -> [String] {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["list"]
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).sorted()
    }
}

enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func request() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
