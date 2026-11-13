import Foundation
@testable import DrevoCore

/// A scratch folder deleted when the value goes away.
final class TempDir {
    let url: URL

    init(_ name: String = "drevo-tests") {
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

struct DuplicateFailed: Error {
    let reason: String
}

extension FileOperations {
    /// Duplicate as the app does it: a copy of the items into their own folder.
    func duplicate(_ urls: [URL]) throws -> ([URL], UndoRecord) {
        let t = Transfer(kind: .copy, sources: urls, destination: urls[0].deletingLastPathComponent())
        t.trash = trash
        let r = t.run()
        if let reason = r.errors.first { throw DuplicateFailed(reason: reason) }
        return (r.outputs, r.undo ?? .created([]))
    }
}
