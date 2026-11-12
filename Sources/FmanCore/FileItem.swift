import Foundation
import UniformTypeIdentifiers

/// One entry in a folder listing: a snapshot of the file's metadata at load time.
public struct FileItem: Hashable, Sendable {
    public let url: URL
    public let name: String
    /// A folder the user can enter. Packages (.app, .bundle…) are not containers.
    public let isContainer: Bool
    /// A directory on disk, including packages.
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isHidden: Bool
    public let isSymbolicLink: Bool
    public let isAlias: Bool
    public let isVolume: Bool
    /// File size in bytes; nil for folders.
    public let size: Int64?
    public let modified: Date?
    public let created: Date?
    public let kind: String
    public let contentType: UTType?

    public static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey, .isAliasFileKey,
        .isVolumeKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
        .localizedTypeDescriptionKey, .contentTypeKey, .localizedNameKey,
    ]

    public init(
        url: URL, name: String, isContainer: Bool, isDirectory: Bool, isPackage: Bool = false,
        isHidden: Bool = false, isSymbolicLink: Bool = false, isAlias: Bool = false,
        isVolume: Bool = false, size: Int64? = nil, modified: Date? = nil, created: Date? = nil,
        kind: String = "", contentType: UTType? = nil
    ) {
        self.url = url
        self.name = name
        self.isContainer = isContainer
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isHidden = isHidden
        self.isSymbolicLink = isSymbolicLink
        self.isAlias = isAlias
        self.isVolume = isVolume
        self.size = size
        self.modified = modified
        self.created = created
        self.kind = kind
        self.contentType = contentType
    }

    /// Reads metadata for `url`. A symlink that points to a folder counts as a container.
    public init(url: URL) throws {
        let values = try url.resourceValues(forKeys: Set(Self.resourceKeys))
        let isSymlink = values.isSymbolicLink ?? false
        var isDir = values.isDirectory ?? false
        var isPackage = values.isPackage ?? false
        if isSymlink {
            let target = url.resolvingSymlinksInPath()
            let targetValues = try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            isDir = targetValues?.isDirectory ?? false
            isPackage = targetValues?.isPackage ?? false
        }
        self.init(
            url: url,
            name: url.lastPathComponent,
            isContainer: isDir && !isPackage,
            isDirectory: isDir,
            isPackage: isPackage,
            isHidden: values.isHidden ?? url.lastPathComponent.hasPrefix("."),
            isSymbolicLink: isSymlink,
            isAlias: (values.isAliasFile ?? false) && !isSymlink,
            isVolume: values.isVolume ?? false,
            size: isDir ? nil : values.fileSize.map(Int64.init),
            modified: values.contentModificationDate,
            created: values.creationDate,
            kind: values.localizedTypeDescription ?? (isDir ? "Folder" : "Document"),
            contentType: values.contentType
        )
    }

    /// Fast path for listings: built from lstat (and stat for symlinks), with kind and
    /// type looked up once per extension.
    init(path: String, name: String, stat st: stat, parentDevice: dev_t?) {
        let url = URL(fileURLWithPath: path)
        let type = st.st_mode & S_IFMT
        let isSymlink = type == S_IFLNK
        var isDir = type == S_IFDIR
        var target = st
        if isSymlink {
            var t = stat()
            if followStat(path, &t) {
                target = t
                isDir = (t.st_mode & S_IFMT) == S_IFDIR
            }
        }
        let ext = (name as NSString).pathExtension
        let contentType = KindCache.type(forExtension: ext, isDirectory: isDir)
        let isPackage = isDir && (contentType?.conforms(to: .package) ?? false)
        let hidden = name.hasPrefix(".") || (st.st_flags & UInt32(UF_HIDDEN)) != 0
        let isVolume = isDir && !isSymlink && parentDevice != nil && st.st_dev != parentDevice
        let executable = !isDir && (target.st_mode & 0o111) != 0
        self.init(
            url: url, name: name, isContainer: isDir && !isPackage, isDirectory: isDir, isPackage: isPackage,
            isHidden: hidden, isSymbolicLink: isSymlink, isAlias: false, isVolume: isVolume,
            size: isDir ? nil : Int64(target.st_size),
            modified: Date(timespec: target.st_mtimespec), created: Date(timespec: target.st_birthtimespec),
            kind: KindCache.kind(forExtension: ext, type: contentType, isDirectory: isDir, isPackage: isPackage,
                                 isSymlink: isSymlink, executable: executable),
            contentType: contentType
        )
    }

    /// Name without the extension, as Finder selects it when renaming.
    public var baseName: String {
        isContainer ? name : (name as NSString).deletingPathExtension
    }
}

/// stat(2) (follows symlinks); a free function so the call isn't read as the struct's init.
private func followStat(_ path: String, _ buf: inout stat) -> Bool {
    stat(path, &buf) == 0
}

extension Date {
    init(timespec ts: timespec) {
        self.init(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000)
    }
}

/// Kind strings and content types per extension, looked up once (Launch Services is slow).
enum KindCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var types: [String: UTType?] = [:]
    nonisolated(unsafe) private static var kinds: [String: String] = [:]

    static func type(forExtension ext: String, isDirectory: Bool) -> UTType? {
        let key = (isDirectory ? "d:" : "f:") + ext.lowercased()
        lock.lock(); defer { lock.unlock() }
        if let cached = types[key] { return cached }
        let t: UTType?
        if ext.isEmpty {
            t = isDirectory ? .folder : .data
        } else {
            t = UTType(filenameExtension: ext, conformingTo: isDirectory ? .directory : .data)
        }
        types[key] = t
        return t
    }

    static func kind(forExtension ext: String, type: UTType?, isDirectory: Bool, isPackage: Bool, isSymlink: Bool, executable: Bool) -> String {
        if isDirectory && !isPackage { return isSymlink ? "Folder (link)" : "Folder" }
        if executable && ext.isEmpty { return "Unix executable" }
        let key = (isPackage ? "p:" : "f:") + ext.lowercased()
        lock.lock()
        if let k = kinds[key] { lock.unlock(); return k }
        lock.unlock()
        var k = type?.localizedDescription ?? (ext.isEmpty ? "Document" : "\(ext.uppercased()) file")
        if !ext.isEmpty, type?.isDynamic == true { k = "\(ext.uppercased()) file" }
        lock.lock(); kinds[key] = k; lock.unlock()
        return k
    }
}
