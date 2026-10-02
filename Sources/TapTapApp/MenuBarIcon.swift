import AppKit

/// The "ripple" mark from the app icon, drawn as a menu bar template image.
enum MenuBarIcon {
    static let active = make(active: true)
    static let paused = make(active: false)

    private static func make(active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            func circle(_ r: CGFloat) -> NSBezierPath {
                NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            }
            let dot = circle(active ? 2.3 : 2.0)
            if active {
                NSColor.black.setFill(); dot.fill()
            } else {
                dot.lineWidth = 1.0; NSColor.black.setStroke(); dot.stroke()
            }
            let inner = circle(5.0)
            inner.lineWidth = 1.1
            NSColor.black.withAlphaComponent(active ? 0.85 : 0.35).setStroke(); inner.stroke()
            let outer = circle(7.8)
            outer.lineWidth = 1.0
            NSColor.black.withAlphaComponent(active ? 0.42 : 0.18).setStroke(); outer.stroke()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = active ? "TapTap" : L10n.text("TapTap (Paused)")
        return img
    }
}
