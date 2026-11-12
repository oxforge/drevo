import Foundation

/// Expands archives in place the way Finder (Archive Utility) does, without Archive
/// Utility revealing the result in a new Finder window.
///
/// - One top-level item in the archive → it lands next to the archive.
/// - Several → they land in a folder named after the archive.
/// - Taken names get " 2", " 3"… (Archive Utility's naming).
public final class ArchiveExtraction: @unchecked Sendable {
    public enum Format: Sendable, Equatable {
        case zip
        /// tar, optionally gzip/bzip2/xz compressed.
        case tar
    }

    public let archive: URL
    public let format: Format
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init?(archive: URL) {
        guard let format = Self.format(of: archive) else { return nil }
        self.archive = archive
        self.format = format
    }

    private static let tarSuffixes = [".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2", ".tar.xz", ".txz"]

    /// Archives fman expands itself; anything else opens in its default app.
    public static func format(of url: URL) -> Format? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") { return .zip }
        if tarSuffixes.contains(where: { name.hasSuffix($0) }) { return .tar }
        return nil
    }

    /// "photos.tar.gz" → "photos".
    public static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        for suffix in [".zip"] + tarSuffixes.sorted(by: { $0.count > $1.count }) where lower.hasSuffix(suffix) {
            let base = String(name.dropLast(suffix.count))
            return base.isEmpty ? name : base
        }
        return (name as NSString).deletingPathExtension
    }

    public enum Failure: LocalizedError, Equatable {
        case tool(String)
        case empty

        public var errorDescription: String? {
            switch self {
            case .tool(let message): return message
            case .empty: return "The archive is empty."
            }
        }
    }

    public struct Cancelled: Error {}

    public func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if p?.isRunning == true { p?.terminate() }
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Extracts and returns what now sits next to the archive (one item, or the new folder).
    /// Blocks; run it off the main thread.
    public func run(fileManager fm: FileManager = .default) throws -> [URL] {
        let destination = archive.deletingLastPathComponent()
        let staging = destination.appendingPathComponent(".fman-extract-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }

        try expand(into: staging)
        if isCancelled { throw Cancelled() }

        let entries = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "__MACOSX" && $0.lastPathComponent != ".DS_Store" }
        guard !entries.isEmpty else { throw Failure.empty }

        let taken = UniqueName.takenIn(destination)
        if entries.count == 1, let only = entries.first {
            let isFolder = only.isDirectoryOnDisk
            let name = UniqueName.numberedName(for: only.lastPathComponent, isFolder: isFolder, taken: taken)
            let dest = destination.appendingPathComponent(name, isDirectory: isFolder)
            try fm.moveItem(at: only, to: dest)
            return [dest]
        }
        let folderName = UniqueName.numberedName(for: Self.baseName(of: archive), isFolder: true, taken: taken)
        let folder = destination.appendingPathComponent(folderName, isDirectory: true)
        // The staging folder becomes the result (the deferred cleanup then finds nothing).
        try fm.moveItem(at: staging, to: folder)
        try? fm.removeItem(at: folder.appendingPathComponent("__MACOSX"))
        return [folder]
    }

    private func expand(into staging: URL) throws {
        let p = Process()
        switch format {
        case .zip:
            // ditto restores resource forks and extended attributes from __MACOSX, like Archive Utility.
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", "--sequesterRsrc", "--rsrc", archive.path, staging.path]
        case .tar:
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["-x", "-f", archive.path, "-C", staging.path]
        }
        let errors = Pipe()
        p.standardError = errors
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw Cancelled() }
        process = p
        lock.unlock()
        try p.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if isCancelled { throw Cancelled() }
        guard p.terminationStatus == 0 else {
            let text = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.tool("Couldn’t expand “\(archive.lastPathComponent)”" + (text.isEmpty ? "." : ": \(text)"))
        }
    }
}
