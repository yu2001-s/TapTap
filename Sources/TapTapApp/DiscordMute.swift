import AppKit
import ApplicationServices
import OSLog
import SwiftUI

/// Discord can ignore simulated keystrokes delivered to its background process.
/// Use the same accessible microphone switch as a click, without activating it.
enum DiscordMute {
    private static var cached: (pid: pid_t, element: AXUIElement)?
    private static let logger = Logger(subsystem: "app.taptap.TapTap", category: "DiscordMute")

    static func isMuteSwitch(role: String, label: String, value: Int?) -> Bool {
        guard ["AXCheckBox", "AXSwitch"].contains(role), let value, (0...1).contains(value) else { return false }
        // Exact labels avoid channel-mute menus, stream badges, and Deafen.
        return ["mute", "unmute", "静音", "取消静音", "靜音", "解除靜音", "取消靜音"]
            .contains(label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func toggle() -> String? {
        guard Accessibility.isTrusted else { return L10n.text("Accessibility Permission Required") }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.hnc.Discord")
            .first(where: { !$0.isTerminated }) else { return L10n.format("Open %@ first", "Discord") }
        let pid = app.processIdentifier
        let wasBackground = !app.isActive
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let element: AXUIElement
        if let cached, cached.pid == pid, matches(cached.element) {
            element = cached.element
        } else {
            self.cached = nil
            guard let found = findSwitch(pid: pid) else {
                logger.error("Discord microphone switch unavailable")
                return L10n.text("Discord's microphone is unavailable. Open its main window or restart Discord. Supported languages: English and Chinese.")
            }
            element = found
            cached = (pid, found)
        }
        guard let before = muteValue(element) else {
            cached = nil
            return L10n.text("Could not read Discord's mute state. Try again.")
        }
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            cached = nil
            return L10n.text("Could not control Discord's microphone. Try again.")
        }
        // Press exactly once; never retry an uncertain toggle, which could undo it.
        // AXPress returning success alone does not prove Discord changed state.
        for _ in 0..<8 {
            if let after = muteValue(element), after != before {
                let focusUnchanged = NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostPID
                logger.info("Confirmed muted=\(after == 1, privacy: .public) targetWasBackground=\(wasBackground, privacy: .public) focusUnchanged=\(focusUnchanged, privacy: .public)")
                return nil
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        cached = nil
        return L10n.text("Discord did not confirm a mute change. Check its microphone button.")
    }

    private static func findSwitch(pid: pid_t) -> AXUIElement? {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.2)
        // Electron exposes its renderer tree after this documented opt-in.
        // https://www.electronjs.org/docs/latest/tutorial/accessibility
        _ = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // Use the explicit window attribute to search window controls rather
        // than the application's menu bar.
        var pending = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        var cursor = 0
        var found: AXUIElement?
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        while cursor < pending.count {
            guard cursor < 2500, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let node = pending[cursor]
            cursor += 1
            if matches(node) {
                // Fail safely if multiple switches have the same label.
                guard found == nil else { return nil }
                found = node
            }
            if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                pending.append(contentsOf: children)
            }
        }
        return found
    }

    private static func matches(_ element: AXUIElement) -> Bool {
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        guard ["AXCheckBox", "AXSwitch"].contains(role) else { return false }
        let labels = [attribute(element, kAXDescriptionAttribute) as? String,
                      attribute(element, kAXTitleAttribute) as? String].compactMap { $0 }
        let value = muteValue(element)
        return labels.contains { isMuteSwitch(role: role, label: $0, value: value) }
    }

    private static func muteValue(_ element: AXUIElement) -> Int? {
        (attribute(element, kAXValueAttribute) as? NSNumber)?.intValue
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

struct DiscordMuteTest: View {
    @State private var error: String?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(L10n.text("Test")) {
                testing = true
                Task { @MainActor in
                    await Task.yield()
                    error = DiscordMute.toggle()
                    testing = false
                }
            }
                .disabled(testing)
                .help(L10n.text("Toggles Discord's microphone without changing focus. Requires Accessibility access."))
            if let error { Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: 240) }
        }
    }
}
