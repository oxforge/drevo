import Foundation
import Testing
@testable import DrevoCore

/// Packages (.app, .rtfd…) are directories, but a copy must keep the extension at the end
/// or it stops being a package: "Notes.rtfd" → "Notes copy.rtfd", never "Notes.rtfd copy".
@Suite struct PackageNamingTests {
    let tmp = TempDir()
    var trashDir: URL { tmp.url.appendingPathComponent(".TestTrash") }
    var ops: FileOperations { FileOperations(trash: FolderTrash(folder: trashDir)) }
    var fm: FileManager { .default }
    func children(_ path: String = "") -> [String] {
        ((try? fm.contentsOfDirectory(atPath: tmp.url.appendingPathComponent(path).path)) ?? []).filter { $0 != ".TestTrash" }.sorted()
    }

    func transfer(_ sources: [URL], to dest: URL, decide: ConflictAction) -> TransferResult {
        let t = Transfer(kind: .copy, sources: sources, destination: dest)
        t.trash = FolderTrash(folder: trashDir)
        t.resolveConflict = { _ in ConflictDecision(decide, applyToAll: true) }
        return t.run()
    }

    @Test func plainFoldersAreToldFromPackages() throws {
        #expect(UniqueName.isPlainFolder(tmp.dir("Photos")))
        #expect(UniqueName.isPlainFolder(tmp.dir("v1.2")), "a dot in a folder's name isn't an extension")
        #expect(!UniqueName.isPlainFolder(tmp.dir("Foo.app")))
        #expect(!UniqueName.isPlainFolder(tmp.dir("Notes.rtfd")))
        #expect(!UniqueName.isPlainFolder(tmp.file("a.txt")))
        #expect(!UniqueName.isPlainFolder(tmp.url.appendingPathComponent("missing")))
        // A link is named like what it points to.
        let toFolder = tmp.url.appendingPathComponent("link.to.folder")
        try fm.createSymbolicLink(at: toFolder, withDestinationURL: tmp.url.appendingPathComponent("Photos"))
        #expect(UniqueName.isPlainFolder(toFolder))
        let toPackage = tmp.url.appendingPathComponent("link.app")
        try fm.createSymbolicLink(at: toPackage, withDestinationURL: tmp.url.appendingPathComponent("Foo.app"))
        #expect(!UniqueName.isPlainFolder(toPackage))
    }

    @Test func duplicateKeepsThePackageExtensionLast() throws {
        let app = tmp.dir("Foo.app")
        tmp.file("Foo.app/Contents/Info.plist", "plist")
        let rtfd = tmp.dir("Notes.rtfd")
        let folder = tmp.dir("v1.2")
        let (made, _) = try ops.duplicate([app, rtfd, folder])
        #expect(made.map(\.lastPathComponent) == ["Foo copy.app", "Notes copy.rtfd", "v1.2 copy"])
        let (again, _) = try ops.duplicate([app])
        #expect(again.map(\.lastPathComponent) == ["Foo copy 2.app"])
        #expect(fm.fileExists(atPath: tmp.url.appendingPathComponent("Foo copy.app/Contents/Info.plist").path))
    }

    @Test func copyIntoTheSameFolderKeepsThePackageExtensionLast() {
        let r = transfer([tmp.dir("Foo.app"), tmp.dir("v1.2")], to: tmp.url, decide: .stop)
        #expect(r.outputs.map(\.lastPathComponent) == ["Foo copy.app", "v1.2 copy"])
    }

    @Test func keepBothKeepsThePackageExtensionLast() {
        let sources = [tmp.dir("src/Foo.app"), tmp.dir("src/Notes.rtfd"), tmp.dir("src/v1.2")]
        tmp.dir("dest/Foo.app")
        tmp.dir("dest/Notes.rtfd")
        tmp.dir("dest/v1.2")
        let r = transfer(sources, to: tmp.url.appendingPathComponent("dest"), decide: .keepBoth)
        #expect(r.outputs.map(\.lastPathComponent) == ["Foo 2.app", "Notes 2.rtfd", "v1.2 2"])
    }

    @Test func trashAndPutBackKeepThePackageExtensionLast() throws {
        let first = try ops.moveToTrash([tmp.dir("Foo.app")])
        let second = try ops.moveToTrash([tmp.dir("Foo.app")])
        #expect(children(".TestTrash") == ["Foo 2.app", "Foo.app"])
        // Put both back while a third "Foo.app" holds the name.
        tmp.dir("Foo.app")
        _ = try ops.undo(first)
        _ = try ops.undo(second)
        #expect(children() == ["Foo 2.app", "Foo 3.app", "Foo.app"])
    }

    @Test func expandedPackageKeepsItsExtensionLast() throws {
        tmp.file("src/Foo.app/Contents/Info.plist", "plist")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", "src/Foo.app", "foo.zip"]
        p.currentDirectoryURL = tmp.url
        try p.run()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0)
        try fm.removeItem(at: tmp.url.appendingPathComponent("src"))
        tmp.dir("Foo.app")
        let out = try #require(ArchiveExtraction(archive: tmp.url.appendingPathComponent("foo.zip"))).run()
        #expect(out.map(\.lastPathComponent) == ["Foo 2.app"])
    }
}

/// Naming many items in one folder reads the folder once, not once per item.
@Suite struct ManyNamesTests {
    let tmp = TempDir()
    var ops: FileOperations { FileOperations(trash: FolderTrash(folder: tmp.url.appendingPathComponent(".TestTrash"))) }
    var fm: FileManager { .default }

    @Test func takenNamesRememberWhatWasAdded() {
        tmp.file("a.txt")
        let names = UniqueName.TakenNames()
        #expect(names.contains("A.TXT", in: tmp.url), "case-insensitive, like the default APFS")
        #expect(!names.contains("b.txt", in: tmp.url))
        names.add("b.txt", in: tmp.url)
        #expect(names.contains("B.txt", in: tmp.url))
        // The same folder through another path shares one set.
        names.add("c.txt", in: tmp.url.appendingPathComponent("."))
        #expect(names.contains("c.txt", in: tmp.url))
        #expect(!names.contains("c.txt", in: tmp.dir("other")))
    }

    @Test func duplicatingManyFilesGivesEachItsOwnName() throws {
        let count = 300
        let sources = (0..<count).map { tmp.file("f\($0).txt", "\($0)") }
        // Copies of the first ten already exist, so those need "copy 2".
        for i in 0..<10 { tmp.file("f\(i) copy.txt", "old") }
        let (made, _) = try ops.duplicate(sources)
        let expected = (0..<count).map { $0 < 10 ? "f\($0) copy 2.txt" : "f\($0) copy.txt" }
        #expect(made.map(\.lastPathComponent) == expected)
        #expect(Set(made).count == count)
        #expect(try String(contentsOf: made[299], encoding: .utf8) == "299")
        #expect(try fm.contentsOfDirectory(atPath: tmp.url.path).count == 2 * count + 10)
    }

    /// Two sources that want the same new name must not collide.
    @Test func duplicateSeesTheNamesItJustMade() throws {
        let a = tmp.file("a.txt", "1")
        let copy = tmp.file("a copy.txt", "2")
        let (made, _) = try ops.duplicate([a, copy, a])
        #expect(made.map(\.lastPathComponent) == ["a copy 2.txt", "a copy 3.txt", "a copy 4.txt"])
    }

    @Test func copyingManyFilesIntoTheirOwnFolderGivesEachItsOwnName() {
        let count = 300
        let sources = (0..<count).map { tmp.file("f\($0).txt", "\($0)") }
        let t = Transfer(kind: .copy, sources: sources + [sources[0]], destination: tmp.url)
        let r = t.run()
        #expect(r.errors == [])
        #expect(r.outputs.map(\.lastPathComponent) == (0..<count).map { "f\($0) copy.txt" } + ["f0 copy 2.txt"])
    }

    @Test func keepBothForManyFilesGivesEachItsOwnName() {
        let count = 300
        let sources = (0..<count).map { tmp.file("src/f\($0).txt", "new") }
        for i in 0..<count { tmp.file("dest/f\(i).txt", "old") }
        // The same name arriving from two folders: the second must not reuse "f0 2.txt".
        let other = tmp.file("src2/f0.txt", "other")
        let t = Transfer(kind: .copy, sources: sources + [other], destination: tmp.url.appendingPathComponent("dest"))
        t.resolveConflict = { _ in ConflictDecision(.keepBoth, applyToAll: true) }
        let r = t.run()
        #expect(r.errors == [])
        #expect(r.outputs.map(\.lastPathComponent) == (0..<count).map { "f\($0) 2.txt" } + ["f0 3.txt"])
    }
}
