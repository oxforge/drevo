import AppKit
import FmanCore

/// Shared formatters and icon cache.
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

    /// "~/oxforge/fman" for display.
    static func abbreviatedPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Display name: localized for system folders ("Applications" stays, "/" → "Macintosh HD").
    static func displayName(_ url: URL) -> String {
        if let name = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName { return name }
        return url.lastPathComponent
    }
}

@MainActor
final class FileIcons {
    static let shared = FileIcons()
    private let cache = NSCache<NSString, NSImage>()

    func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: key)
        return image
    }

    func invalidate(_ url: URL) {
        cache.removeObject(forKey: url.path as NSString)
    }
}
