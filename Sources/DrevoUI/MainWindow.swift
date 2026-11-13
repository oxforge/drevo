import AppKit

/// The main window. A key down reaches `sendEvent` only after the main menu passed on it,
/// so this is where keys no menu item carries get a turn before the focused view.
final class MainWindow: NSWindow {
    /// Runs a command for a key no menu item claimed; true when it handled the key.
    var unclaimedKeyHandler: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, unclaimedKeyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}
