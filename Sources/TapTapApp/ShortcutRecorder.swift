import AppKit
import SwiftUI

/// Click, then press and release a key combination; unmodified Esc cancels.
struct ShortcutRecorder: View {
    @Binding var action: GestureAction
    @StateObject private var capture = ShortcutCapture()

    var body: some View {
        Button {
            if capture.isRecording {
                capture.stop()
            } else {
                capture.start { shortcut in
                    var captured = action
                    captured.keyCode = shortcut.keyCode
                    captured.modifiers = shortcut.modifiers
                    captured.keyLabel = shortcut.label
                    action = captured
                }
            }
        } label: {
            Text(capture.isRecording ? L10n.text("Press a shortcut…") : (action.keyCode == nil ? L10n.text("Record Shortcut") : action.summary))
                .frame(minWidth: 110)
        }
        .help(L10n.text("Click and press a key combination. Esc cancels; Edit lets you choose keys manually."))
        .onDisappear { capture.stop() }
    }
}
