import AppKit
import SwiftUI

/// Small translucent banner near the bottom of the screen confirming a recognized gesture.
@MainActor
enum HUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(slot: GestureSlot, action: GestureAction, ran: Bool, error: String? = nil) {
        let detail: String
        if let error {
            detail = error
        } else if action.kind == .none {
            detail = L10n.text("No Action Assigned")
        } else if !ran {
            detail = L10n.text("Accessibility Permission Required")
        } else {
            detail = action.summary
        }
        let view = HUDView(symbol: slot.symbol, title: slot.title, detail: detail, dimmed: !ran)
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize

        let p = panel ?? makePanel()
        p.contentView = host
        p.setContentSize(host.fittingSize)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.minY + 80))
        }
        p.alphaValue = 1
        p.orderFrontRegardless()
        panel = p

        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return p
    }
}

private struct HUDView: View {
    let symbol: String
    let title: String
    let detail: String
    let dimmed: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(dimmed ? 0.75 : 1)
        .fixedSize()
    }
}
