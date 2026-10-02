import AppKit

/// Captures a shortcut before macOS invokes a system shortcut. The event tap is
/// present only while recording, and ignores input whenever TapTap is inactive.
@MainActor
final class ShortcutCapture: ObservableObject {
    private static weak var active: ShortcutCapture?
    @Published private(set) var isRecording = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var localMonitor: Any?
    private var windowCloseObserver: NSObjectProtocol?
    private var fnPressed = false
    private var pending: RecordedShortcut?
    private var onCapture: ((RecordedShortcut) -> Void)?

    static func cancelActive() { active?.stop() }

    func start(onCapture: @escaping (RecordedShortcut) -> Void) {
        Self.active?.stop()
        stop()
        Self.active = self
        self.onCapture = onCapture
        isRecording = true
        fnPressed = NSEvent.modifierFlags.contains(.function)
        NSApp.activate(ignoringOtherApps: true)

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        if Accessibility.isTrusted {
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                   options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let capture = Unmanaged<ShortcutCapture>.fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated { capture.handle(type: type, event: event) }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        }
        if let tap, let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
            source = runLoopSource
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            if let tap { CFMachPortInvalidate(tap) }
            tap = nil
        }
        // App-routed events may bypass the event tap, and Cocoa may omit key-up
        // for Command combinations. Also monitor this app's own events.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.consume(type: event.type, keyCode: event.keyCode, flags: event.modifierFlags,
                                isRepeat: event.type == .keyDown && event.isARepeat, waitForKeyUp: false) ? nil : event
        }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func stop() {
        if Self.active === self { Self.active = nil }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
        tap = nil
        source = nil
        localMonitor = nil
        windowCloseObserver = nil
        pending = nil
        onCapture = nil
        if isRecording { isRecording = false }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if isRecording, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let eventType: NSEvent.EventType
        switch type {
        case .keyDown: eventType = .keyDown
        case .keyUp: eventType = .keyUp
        case .flagsChanged: eventType = .flagsChanged
        default: return Unmanaged.passUnretained(event)
        }
        guard NSApp.isActive else { return Unmanaged.passUnretained(event) }
        let consumed = consume(type: eventType,
                               keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                               flags: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)),
                               isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        return consumed ? nil : Unmanaged.passUnretained(event)
    }

    private func consume(type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags, isRepeat: Bool,
                         waitForKeyUp: Bool = true) -> Bool {
        guard isRecording else { return false }
        if type == .flagsChanged {
            if keyCode == 63 { fnPressed = flags.contains(.function) }
            return false
        }
        if type == .keyDown {
            guard pending == nil, !isRepeat else { return true }
            pending = RecordedShortcut(keyCode: keyCode,
                                       modifiers: RecordedShortcut.modifiers(from: flags, fnPressed: fnPressed).rawValue)
            if !waitForKeyUp, let pending { finish(pending) }
            return true
        }
        if type == .keyUp, let pending, pending.keyCode == keyCode {
            finish(pending)
            return true
        }
        return false
    }

    private func finish(_ shortcut: RecordedShortcut) {
        let callback = onCapture
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.stop()
            if !shortcut.isRecordingCancel { callback?(shortcut) }
        }
    }
}
