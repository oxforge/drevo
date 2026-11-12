import Foundation

/// A scratch folder deleted when the value goes away.
final class TempDir {
    let url: URL

    init(_ name: String = "fman-tests") {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ path: String, _ contents: String = "x", modified: Date? = nil) -> URL {
        let u = url.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! contents.data(using: .utf8)!.write(to: u)
        if let modified {
            try! FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: u.path)
        }
        return u
    }

    @discardableResult
    func dir(_ path: String) -> URL {
        let u = url.appendingPathComponent(path, isDirectory: true)
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}
