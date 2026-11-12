import AppKit

/// Renders a window into a PNG for unattended visual review.
///
/// Prefers a real window-server capture (`screencapture -l`), which draws macOS 26 glass
/// materials correctly; falls back to offscreen `cacheDisplay` (glass panels come out blank)
/// when capture isn't permitted.
enum Snapshot {
    enum Failure: Error { case noFrameView, encode }

    @MainActor
    /// `overlays` are views inside glass panels that offscreen capture skips; they're drawn
    /// again on a plain background at their window position.
    static func write(window: NSWindow, overlays: [NSView] = [], to url: URL) throws {
        if capture(window: window, to: url) { return }
        guard let frameView = window.contentView?.superview else { throw Failure.noFrameView }
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { throw Failure.encode }
        frameView.cacheDisplay(in: bounds, to: rep)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for overlay in overlays where overlay.window === window && !overlay.isHidden {
            let rect = overlay.convert(overlay.bounds, to: frameView)
            guard let overlayRep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) else { continue }
            overlay.cacheDisplay(in: overlay.bounds, to: overlayRep)
            var fill = NSColor.gray
            frameView.effectiveAppearance.performAsCurrentDrawingAppearance {
                fill = NSColor.underPageBackgroundColor.usingColorSpace(.deviceRGB) ?? .gray
            }
            fill.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: -4, dy: -4), xRadius: 14, yRadius: 14).fill()
            overlayRep.draw(in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else { throw Failure.encode }
        try data.write(to: url)
    }

    /// Window-server capture of just this window, without its shadow.
    @MainActor
    private static func capture(window: NSWindow, to url: URL) -> Bool {
        window.displayIfNeeded()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l\(window.windowNumber)", url.path]
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        guard p.terminationStatus == 0, let image = NSImage(contentsOf: url) else { return false }
        // Without Screen Recording permission the capture is wallpaper only; we can't
        // tell reliably, so trust a capture of the right size.
        return image.size.width > 0
    }
}
