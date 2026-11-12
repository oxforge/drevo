import Foundation
import Testing
@testable import FmanCore

@Suite struct ArchiveExtractionTests {
    let tmp = TempDir()
    var fm: FileManager { .default }

    func sh(_ args: [String], in dir: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        p.currentDirectoryURL = dir
        try! p.run()
        p.waitUntilExit()
        precondition(p.terminationStatus == 0, "\(args) failed")
    }

    /// A zip made like Finder's Compress: `ditto -c -k --sequesterRsrc --keepParent`.
    @discardableResult
    func zip(_ item: String, to name: String) -> URL {
        sh(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", item, name], in: tmp.url)
        return tmp.url.appendingPathComponent(name)
    }

    func children(_ path: String = "") -> [String] {
        ((try? fm.contentsOfDirectory(atPath: tmp.url.appendingPathComponent(path).path)) ?? []).sorted()
    }

    @Test func recognisesFormats() {
        #expect(ArchiveExtraction.format(of: URL(fileURLWithPath: "/a/x.ZIP")) == .zip)
        #expect(ArchiveExtraction.format(of: URL(fileURLWithPath: "/a/x.tar.gz")) == .tar)
        #expect(ArchiveExtraction.format(of: URL(fileURLWithPath: "/a/x.tgz")) == .tar)
        #expect(ArchiveExtraction.format(of: URL(fileURLWithPath: "/a/x.dmg")) == nil)
        #expect(ArchiveExtraction.baseName(of: URL(fileURLWithPath: "/a/photos.tar.gz")) == "photos")
    }

    @Test func singleFolderLandsNextToTheArchive() throws {
        tmp.file("src/Assets/a.txt", "A")
        let archive = zip("src/Assets", to: "assets.zip")
        try fm.removeItem(at: tmp.url.appendingPathComponent("src"))
        let out = try #require(ArchiveExtraction(archive: archive)).run()
        #expect(out.map(\.lastPathComponent) == ["Assets"])
        #expect(try String(contentsOf: tmp.url.appendingPathComponent("Assets/a.txt"), encoding: .utf8) == "A")
        #expect(children() == ["Assets", "assets.zip"], "no staging folder or __MACOSX left behind")
    }

    @Test func takenNameGetsANumber() throws {
        tmp.file("src/Assets/a.txt", "A")
        let archive = zip("src/Assets", to: "assets.zip")
        tmp.dir("Assets")
        let out = try #require(ArchiveExtraction(archive: archive)).run()
        #expect(out.map(\.lastPathComponent) == ["Assets 2"])
    }

    @Test func severalItemsGoIntoAFolderNamedAfterTheArchive() throws {
        tmp.file("src/one.txt", "1")
        tmp.file("src/two.txt", "2")
        sh(["/usr/bin/tar", "-czf", "bundle.tar.gz", "-C", "src", "one.txt", "two.txt"], in: tmp.url)
        let out = try #require(ArchiveExtraction(archive: tmp.url.appendingPathComponent("bundle.tar.gz"))).run()
        #expect(out.map(\.lastPathComponent) == ["bundle"])
        #expect(children("bundle") == ["one.txt", "two.txt"])
    }

    @Test func extendedAttributesSurvive() throws {
        let file = tmp.file("src/Folder/a.txt", "A")
        sh(["/usr/bin/xattr", "-w", "com.example.fman", "kept", file.path], in: tmp.url)
        let archive = zip("src/Folder", to: "f.zip")
        try fm.removeItem(at: tmp.url.appendingPathComponent("src"))
        _ = try #require(ArchiveExtraction(archive: archive)).run()
        let size = getxattr(tmp.url.appendingPathComponent("Folder/a.txt").path, "com.example.fman", nil, 0, 0, 0)
        #expect(size == 4)
    }

    @Test func brokenArchiveFailsCleanly() throws {
        let bad = tmp.file("broken.zip", "not a zip at all")
        #expect(throws: ArchiveExtraction.Failure.self) { try ArchiveExtraction(archive: bad)!.run() }
        #expect(children() == ["broken.zip"])
    }
}
