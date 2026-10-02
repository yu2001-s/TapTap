import AppKit
import SwiftUI

struct ShortcutEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var action: GestureAction
    @State private var showingEditor = false
    @State private var testTask: Task<Void, Never>?
    @State private var secondsRemaining = 0
    @State private var testError: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                ShortcutRecorder(action: $action)
                Button(L10n.text("Edit…")) {
                    ShortcutCapture.cancelActive()
                    showingEditor = true
                }
                .popover(isPresented: $showingEditor, arrowEdge: .bottom) {
                    ShortcutEditForm(action: $action) { showingEditor = false }
                }
                Button(secondsRemaining > 0 ? "\(secondsRemaining)…" : L10n.text("Test")) {
                    if testTask != nil {
                        cancelTest()
                    } else {
                        ShortcutCapture.cancelActive()
                        testError = nil
                        let savedAction = action
                        testTask = Task { @MainActor in
                            for second in stride(from: 3, through: 1, by: -1) {
                                secondsRemaining = second
                                do { try await Task.sleep(for: .seconds(1)) }
                                catch { return }
                            }
                            testError = ActionRunner.run(savedAction)
                            secondsRemaining = 0
                            testTask = nil
                        }
                    }
                }
                .disabled(action.keyCode == nil || !model.accessibilityTrusted)
                .help(action.keyboardAppPath == nil
                    ? L10n.text("Sends the shortcut in 3 seconds. Switch to the desired app; click again to cancel.")
                    : L10n.text("Sends to the selected app in 3 seconds without changing focus. Click again to cancel."))
            }
            if let testError { Text(testError).font(.caption).foregroundStyle(.red) }
        }
        .onDisappear { cancelTest() }
        .onChange(of: action) { _, _ in cancelTest(); testError = nil }
    }

    private func cancelTest() {
        testTask?.cancel()
        testTask = nil
        secondsRemaining = 0
    }
}

private struct ShortcutEditForm: View {
    @Binding var action: GestureAction
    let close: () -> Void
    @State private var group: ShortcutKeyGroup
    @State private var keyCode: UInt16
    @State private var modifiers: UInt
    @State private var targetPath: String
    private let targetApps: [String]

    init(action: Binding<GestureAction>, close: @escaping () -> Void) {
        _action = action
        self.close = close
        let code = action.wrappedValue.keyCode ?? 0
        _group = State(initialValue: ShortcutKey.find(code)?.group ?? .letters)
        _keyCode = State(initialValue: code)
        _modifiers = State(initialValue: action.wrappedValue.modifiers)
        let path = action.wrappedValue.keyboardAppPath ?? ""
        _targetPath = State(initialValue: path)
        var paths = NSWorkspace.shared.runningApplications.compactMap { app -> String? in
            guard app.activationPolicy == .regular else { return nil }
            return app.bundleURL?.path
        }
        if !path.isEmpty { paths.append(path) }
        targetApps = Array(Set(paths)).sorted { GestureAction.appName($0) < GestureAction.appName($1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("Custom Keyboard Shortcut")).font(.headline)
            Text(GestureAction.shortcutString(keyLabel: ShortcutKey.label(keyCode), modifiers: modifiers))
                .font(.system(size: 24, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            Form {
                Picker(L10n.text("Key Category"), selection: $group) {
                    ForEach(ShortcutKeyGroup.allCases) { Text($0.title).tag($0) }
                }
                Picker(L10n.text("Key"), selection: $keyCode) {
                    ForEach(group.keys) { Text($0.label).tag($0.code) }
                    if ShortcutKey.find(keyCode) == nil {
                        Text(ShortcutKey.label(keyCode)).tag(keyCode)
                    }
                }
            }
            Text(L10n.text("Modifiers (choose any combination, or none)")).font(.subheadline)
            HStack(spacing: 6) {
                modifier("⌘", flag: .command, name: "Command")
                modifier("⌥", flag: .option, name: "Option")
                modifier("⌃", flag: .control, name: "Control")
                modifier("⇧", flag: .shift, name: "Shift")
                modifier("fn", flag: .function, name: "Fn")
            }
            Text(L10n.text("Supports single keys, Esc, F1–F20, the numeric keypad, and combinations such as ⌘Tab or ⌃←. System shortcuts follow your macOS keyboard settings."))
                .font(.caption).foregroundStyle(.secondary)
            Form {
                Picker(L10n.text("Send To"), selection: $targetPath) {
                    Text(L10n.text("Current App / Global Shortcut")).tag("")
                    ForEach(targetApps, id: \.self) { path in
                        Text(GestureAction.appName(path)).tag(path)
                    }
                }
            }
            Text(L10n.text("A selected app can receive keys in the background. Open an app first to add it to this list."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L10n.text("Clear")) {
                    var cleared = action
                    cleared.keyCode = nil
                    cleared.modifiers = 0
                    cleared.keyLabel = ""
                    action = cleared
                    close()
                }
                .disabled(action.keyCode == nil)
                Button(L10n.text("Cancel"), action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("Save")) {
                    var edited = action
                    edited.keyCode = keyCode
                    edited.modifiers = modifiers
                    edited.keyLabel = ShortcutKey.label(keyCode)
                    edited.keyboardAppPath = targetPath.isEmpty ? nil : targetPath
                    action = edited
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onChange(of: group) { _, newGroup in
            if ShortcutKey.find(keyCode)?.group != newGroup {
                keyCode = newGroup.keys[0].code
            }
        }
    }

    private func modifier(_ title: String, flag: NSEvent.ModifierFlags, name: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { modifiers & flag.rawValue != 0 },
            set: { on in
                if on { modifiers |= flag.rawValue } else { modifiers &= ~flag.rawValue }
            }
        ))
        .toggleStyle(.button)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(name)
        .help(name)
    }
}
