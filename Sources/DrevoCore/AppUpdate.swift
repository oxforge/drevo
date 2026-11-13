import Foundation

/// A release version such as "0.3.1" or the tag "v0.4.0-beta1".
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let numbers: [Int]
    /// The part after "-"; a version with one comes before the same numbers without.
    public let suffix: String?

    /// Nil unless the text is dot-separated numbers, with an optional "v" before and "-suffix" after.
    public init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("v") { s = s.dropFirst() }
        let parts = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let head = parts.first else { return nil }
        let fields = head.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = fields.compactMap { $0.allSatisfy { ("0"..."9").contains($0) } ? Int($0) : nil }
        guard numbers.count == fields.count else { return nil }
        self.numbers = numbers
        suffix = parts.count > 1 ? String(parts[1]) : nil
    }

    public var description: String {
        numbers.map(String.init).joined(separator: ".") + (suffix.map { "-" + $0 } ?? "")
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let x = i < a.numbers.count ? a.numbers[i] : 0
            let y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        switch (a.suffix, b.suffix) {
        case let (x?, y?): return x.compare(y, options: .numeric) == .orderedAscending
        case (.some, nil): return true
        default: return false
        }
    }
}

/// A published release, as GitHub describes it.
public struct AppRelease: Equatable, Sendable {
    public let version: AppVersion
    /// The release notes (Markdown).
    public let notes: String
    /// The release's web page.
    public let page: URL
    /// The disk image to install from, if the release has one.
    public let diskImage: URL?

    public init(version: AppVersion, notes: String, page: URL, diskImage: URL?) {
        self.version = version
        self.notes = notes
        self.page = page
        self.diskImage = diskImage
    }

    public struct Unreadable: Error, LocalizedError {
        public var errorDescription: String? { "The answer from GitHub wasn’t a release." }
    }

    /// Reads GitHub's "latest release" answer. Links must be https.
    public static func parse(_ data: Data) throws -> AppRelease {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        struct Body: Decodable {
            let tag_name: String
            let html_url: String
            let body: String?
            let assets: [Asset]?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data),
              let version = AppVersion(body.tag_name),
              let page = secureURL(body.html_url) else { throw Unreadable() }
        let image = body.assets?.first { $0.name.lowercased().hasSuffix(".dmg") }
        return AppRelease(version: version, notes: body.body ?? "", page: page,
                          diskImage: image.flatMap { secureURL($0.browser_download_url) })
    }

    private static func secureURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https" else { return nil }
        return url
    }
}

/// Replaces an installed app bundle with a new one in two steps: `stage` copies the new
/// bundle next to the installed one (slow, can fail harmlessly), `swap` renames it into
/// place (fast, and the old bundle comes back if it fails).
public enum AppInstall {
    public struct Failure: Error, LocalizedError {
        public let reason: String
        public var errorDescription: String? { reason }
    }

    /// Why `app` can't be replaced where it is, or nil when it can.
    public static func obstacle(for app: URL, fileManager: FileManager = .default) -> String? {
        guard app.pathExtension == "app" else { return "This copy of Drevo isn’t running from an app bundle." }
        let folder = app.deletingLastPathComponent().path
        if folder.contains("/AppTranslocation/") {
            return "Drevo is running from a temporary location. Move it to the Applications folder first."
        }
        if !fileManager.isWritableFile(atPath: folder) { return "Drevo can’t write to “\(folder)”." }
        return nil
    }

    /// Copies `newApp` into the folder of `installed` under a hidden name and returns the copy.
    public static func stage(_ newApp: URL, for installed: URL, fileManager: FileManager = .default) throws -> URL {
        let staged = installed.deletingLastPathComponent()
            .appendingPathComponent(".\(installed.deletingPathExtension().lastPathComponent)-update-\(UUID().uuidString).app")
        do {
            try fileManager.copyItem(at: newApp, to: staged)
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
        return staged
    }

    /// Puts `staged` where `installed` is and removes the old bundle.
    public static func swap(staged: URL, installed: URL, fileManager: FileManager = .default) throws {
        let old = installed.deletingLastPathComponent()
            .appendingPathComponent(".\(installed.deletingPathExtension().lastPathComponent)-old-\(UUID().uuidString).app")
        try fileManager.moveItem(at: installed, to: old)
        do {
            try fileManager.moveItem(at: staged, to: installed)
        } catch {
            try? fileManager.moveItem(at: old, to: installed)
            throw error
        }
        try? fileManager.removeItem(at: old)
    }
}
