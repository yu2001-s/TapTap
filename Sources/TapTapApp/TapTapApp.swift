import AppKit
import SwiftUI

@main
struct TapTapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { model.config.showMenuBarIcon },
            set: { show in
                guard model.config.showMenuBarIcon != show else { return }
                DispatchQueue.main.async { model.config.showMenuBarIcon = show }
            }
        )) {
            MenuContent().environmentObject(model)
        } label: {
            Image(nsImage: model.status == .running ? MenuBarIcon.active : MenuBarIcon.paused)
                .accessibilityLabel(model.status == .running ? "TapTap" : L10n.text("TapTap (Paused)"))
        }

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

private struct MenuContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Text("TapTap · \(model.statusText)")
        if let e = model.lastEvent {
            Text(L10n.format("Latest: %@ → %@  %@", e.slot.title, model.config.action(e.slot).summary, e.at.formatted(date: .omitted, time: .shortened)))
        }
        if model.needsAccessibility {
            Button(L10n.text("⚠️ Accessibility Permission Required…")) { model.requestAccessibility() }
        }
        Divider()
        Toggle(L10n.text("Enable"), isOn: $model.config.enabled)
            .disabled(model.status == .noSensor)
        Divider()
        ForEach(GestureSlot.allCases) { slot in
            Text("\(slot.title): \(model.config.action(slot).summary)")
        }
        Divider()
        Button(L10n.text("Settings…")) { model.showSettings() }
            .keyboardShortcut(",")
        Button(L10n.text("Quit TapTap")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
