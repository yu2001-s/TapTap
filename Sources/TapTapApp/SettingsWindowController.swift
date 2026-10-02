import AppKit
import SwiftUI
import Carbon

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 660, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = L10n.text("TapTap Settings")
            window.identifier = NSUserInterfaceItemIdentifier("TapTapSettings")
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 620, height: 600)
            window.contentView = NSHostingView(rootView: SettingsView().environmentObject(model))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func refreshTitle() { window?.title = L10n.text("TapTap Settings") }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel { AppModel.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["TAPTAP_SNAPSHOT"] == nil else { return }
        let isBackgroundLaunch = Self.isBackgroundLaunch(NSAppleEventManager.shared().currentAppleEvent)
        if CommandLine.arguments.contains("--settings") || (!model.config.showMenuBarIcon && !isBackgroundLaunch) {
            model.showSettings()
        }
    }

    static func isBackgroundLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard event?.eventID == AEEventID(kAEOpenApplication),
              let launchKind = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue else { return false }
        return launchKind == OSType(keyAELaunchedAsLogInItem) || launchKind == OSType(keyAELaunchedAsServiceItem)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.showSettings()
        return false
    }
}
