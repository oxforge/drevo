import AppKit

/// The shared icon cache: one Finder icon per path.
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
}
