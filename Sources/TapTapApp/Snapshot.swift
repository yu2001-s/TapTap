import AppKit
import SwiftUI

/// Debug aid: `TAPTAP_SNAPSHOT=/path/out.png` renders the settings view to a PNG and quits.
@MainActor
enum Snapshot {
    /// Menu bar icons at 8× on light and dark backgrounds, next to the settings PNG.
    private static func writeMenuIcons(next path: String) {
        let scale: CGFloat = 8
        let w = 18 * scale, pad = 6 * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(4 * (w + pad)), pixelsHigh: Int(w + 2 * pad),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (i, (icon, dark)) in [(MenuBarIcon.active, false), (MenuBarIcon.paused, false),
                                  (MenuBarIcon.active, true), (MenuBarIcon.paused, true)].enumerated() {
            let x = CGFloat(i) * (w + pad)
            (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSRect(x: x, y: 0, width: w + pad, height: w + 2 * pad).fill()
            let tinted = NSImage(size: icon.size, flipped: false) { r in
                icon.draw(in: r)
                (dark ? NSColor.white : NSColor.black).set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: x + pad / 2, y: pad, width: w, height: w))
        }
        NSGraphicsContext.restoreGraphicsState()
        let url = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("menubar.png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func runIfRequested(model: AppModel) {
        guard let out = ProcessInfo.processInfo.environment["TAPTAP_SNAPSHOT"] else { return }
        writeMenuIcons(next: out)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let host = NSHostingView(rootView: SettingsView().environmentObject(model)
                .frame(width: 660, height: 1040))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.setContentSize(host.fittingSize)
            window.orderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let view = window.contentView!
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                NSApp.terminate(nil)
            }
        }
    }
}
