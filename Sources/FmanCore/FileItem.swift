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

    /// Name without the extension, as Finder selects it when renaming.
    public var baseName: String {
        isContainer ? name : (name as NSString).deletingPathExtension
    }
}
