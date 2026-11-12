import AppKit
import DrevoCore

/// Shared formatters.
@MainActor
enum Formatting {
    static let byteCount: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static let relativeDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    static let absoluteDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "--" }
        return byteCount.string(fromByteCount: bytes)
    }

    static func date(_ date: Date?, relative: Bool) -> String {
        guard let date else { return "--" }
        return (relative ? relativeDate : absoluteDate).string(from: date)
    }

    static func itemCount(_ n: Int) -> String {
        n == 1 ? "1 item" : "\(n) items"
    }

    /// "~/projects/drevo" for display.
    static func abbreviatedPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Display name: localized for system folders ("Applications" stays, "/" → "Macintosh HD").
    static func displayName(_ url: URL) -> String {
        if let name = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName { return name }
        return url.lastPathComponent
    }
}
