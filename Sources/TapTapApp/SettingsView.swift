import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var shortcuts: [String] = []

    var body: some View {
        Form {
            Section {
                Toggle(L10n.text("Enable TapTap"), isOn: $model.config.enabled)
                LabeledContent(L10n.text("Status")) {
                    Text(model.statusText).foregroundStyle(model.status == .running ? .green : .secondary)
                }
            }

            Section(L10n.text("Gestures")) {
                ForEach(GestureSlot.allCases) { slot in
                    ActionRow(slot: slot, shortcuts: shortcuts, action: Binding(
                        get: { model.config.action(slot) },
                        set: { model.setAction($0, for: slot) }
                    ))
                }
                Text(L10n.text("Double- or triple-tap the left or right palm rest. Single taps, desk taps, typing, and movement are filtered out."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L10n.text("Sensitivity")) {
                VStack(alignment: .leading) {
                    Slider(value: $model.config.minPeak, in: 4...20, step: 1) {
                        Text(L10n.text("Minimum Tap Strength"))
                    } minimumValueLabel: {
                        Text(L10n.text("Sensitive"))
                    } maximumValueLabel: {
                        Text(L10n.text("Firm"))
                    }
                    Text(L10n.format("%d mg. Lower the threshold if light taps are missed; raise it if resting your hands causes accidental triggers.", Int(model.config.minPeak)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(L10n.text("General")) {
                Picker(L10n.text("Language"), selection: $model.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                Toggle(L10n.text("Show Menu Bar Icon"), isOn: $model.config.showMenuBarIcon)
                Text(L10n.text("TapTap keeps running when the icon is hidden. Open TapTap from Applications to show settings again."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.text("Show On-Screen Feedback"), isOn: $model.config.showHUD)
                Toggle(L10n.text("Launch at Login"), isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                if let err = model.launchAtLoginError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            Section(L10n.text("Permissions")) {
                LabeledContent(L10n.text("Accessibility")) {
                    if model.accessibilityTrusted {
                        Label(L10n.text("Granted"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button(L10n.text("Grant Access…")) { model.requestAccessibility() }
                    }
                }
                Text(L10n.text("Media keys and keyboard shortcuts require Accessibility access. Opening apps, running Shortcuts, and shell commands do not."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button(L10n.text("Quit TapTap")) { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 620, idealWidth: 660, minHeight: 600, idealHeight: 740)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.global().async {
                let list = ActionRunner.listShortcuts()
                DispatchQueue.main.async { shortcuts = list }
            }
        }
    }
}

private struct ActionRow: View {
    let slot: GestureSlot
    let shortcuts: [String]
    @Binding var action: GestureAction

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(slot.title, systemImage: slot.symbol)
                    .frame(width: 148, alignment: .leading)
                Picker("", selection: $action.kind) {
                    ForEach(GestureAction.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                detail
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var detail: some View {
        switch action.kind {
        case .none:
            EmptyView()
        case .media:
            Picker("", selection: $action.media) {
                ForEach(MediaKey.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        case .keyboard:
            ShortcutEditor(action: $action)
        case .openApp:
            Button(action.appPath.isEmpty ? L10n.text("Choose App…") : action.summary) { pickApp() }
        case .shortcut:
            if shortcuts.isEmpty {
                TextField(L10n.text("Shortcut Name"), text: $action.shortcutName).frame(width: 180)
            } else {
                Picker("", selection: $action.shortcutName) {
                    Text(L10n.text("Select a Shortcut")).tag("")
                    ForEach(shortcuts, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)
            }
        case .shell:
            TextField(L10n.text("e.g. open ~/Downloads"), text: $action.command)
                .font(.system(.body, design: .monospaced))
                .frame(width: 220)
        }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            action.appPath = url.path
        }
    }
}
