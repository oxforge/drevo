import AppKit

/// Renders a window (frame, toolbar and content) into a PNG for unattended visual review.
enum Snapshot {
    enum Failure: Error { case noFrameView, encode }

    @MainActor
    static func write(window: NSWindow, to url: URL) throws {
        guard let frameView = window.contentView?.superview else { throw Failure.noFrameView }
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { throw Failure.encode }
        frameView.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw Failure.encode }
        try data.write(to: url)
    }
}
