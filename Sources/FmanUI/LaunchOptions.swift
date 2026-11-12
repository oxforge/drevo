import Foundation

/// Command-line switches. Used for unattended snapshots and for `open -a fman --args …`.
public struct LaunchOptions: Equatable {
    /// Render the main window to this PNG and quit.
    public var snapshotPath: String?
    /// Force an appearance: "light" or "dark". nil follows the system.
    public var appearance: String?
    /// Folders to show in the panes, left to right.
    public var openPaths: [String] = []
    /// Use throwaway settings instead of the user's (implied by `--snapshot`).
    public var ephemeralSettings = false
    /// Snapshot only: run this command in the console first (shows the shell UI).
    public var snapshotCommand: String?
    /// Snapshot the Settings window instead of the main window.
    public var snapshotSettings = false

    public init() {}

    public init(arguments: [String]) {
        var it = arguments.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--snapshot":
                snapshotPath = it.next()
                ephemeralSettings = true
            case "--dark":
                appearance = "dark"
            case "--light":
                appearance = "light"
            case "--open":
                if let p = it.next() { openPaths.append(p) }
            case "--ephemeral":
                ephemeralSettings = true
            case "--snapshot-command":
                snapshotCommand = it.next()
            case "--snapshot-settings":
                snapshotSettings = true
            default:
                // Finder-style launches pass -psn_… and AppleEvent args; ignore unknowns.
                break
            }
        }
    }
}
