import Foundation

/// Lets a background operation report progress at most ~30 times a second: a delete or
/// an undo of thousands of small items would otherwise queue an update on the main
/// thread for each one.
struct ProgressThrottle {
    private var last = Date.distantPast

    /// True when enough time has passed since the last update that went out.
    mutating func isDue() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(last) > 0.033 else { return false }
        last = now
        return true
    }
}
