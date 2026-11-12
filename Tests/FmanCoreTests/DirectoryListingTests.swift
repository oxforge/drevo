import Foundation
import Testing
@testable import FmanCore

@Suite struct DirectoryListingTests {
    let tmp = TempDir()

    init() {
        tmp.dir("Zeta")
        tmp.dir("alpha")
        tmp.file("file10.txt", "1234567890", modified: Date(timeIntervalSince1970: 3000))
        tmp.file("file2.txt", "12", modified: Date(timeIntervalSince1970: 1000))
        tmp.file(".hidden", "x", modified: Date(timeIntervalSince1970: 2000))
        tmp.dir("App.app/Contents")
    }

    @Test func hidesDotfilesUnlessAsked() throws {
        let names = try DirectoryListing.load(tmp.url, options: ListingOptions()).map(\.name)
        #expect(!names.contains(".hidden"))
        let all = try DirectoryListing.load(tmp.url, options: ListingOptions(showHidden: true)).map(\.name)
        #expect(all.contains(".hidden"))
    }

    @Test func foldersFirstThenFinderNameOrder() throws {
        let names = try DirectoryListing.load(tmp.url, options: ListingOptions()).map(\.name)
        // Packages are files; numbers sort naturally (file2 before file10).
        #expect(names == ["alpha", "Zeta", "App.app", "file2.txt", "file10.txt"])
    }

    @Test func mixedWhenFoldersFirstIsOff() throws {
        let opts = ListingOptions(sort: FileSort(key: .name, ascending: true, foldersFirst: false))
        let names = try DirectoryListing.load(tmp.url, options: opts).map(\.name)
        #expect(names == ["alpha", "App.app", "file2.txt", "file10.txt", "Zeta"])
    }

    @Test func sortsBySizeDescending() throws {
        let opts = ListingOptions(sort: FileSort(key: .size, ascending: false, foldersFirst: false))
        let names = try DirectoryListing.load(tmp.url, options: opts).map(\.name)
        #expect(names.first == "file10.txt")
        #expect(names.prefix(2) == ["file10.txt", "file2.txt"])
    }

    @Test func sortsByModified() throws {
        let opts = ListingOptions(showHidden: true, sort: FileSort(key: .modified, ascending: true, foldersFirst: true))
        let files = try DirectoryListing.load(tmp.url, options: opts).filter { !$0.isContainer && !$0.isPackage }.map(\.name)
        #expect(files == ["file2.txt", ".hidden", "file10.txt"])
    }

    @Test func filterIsCaseInsensitiveSubstring() throws {
        let names = try DirectoryListing.load(tmp.url, options: ListingOptions(filter: "FILE1")).map(\.name)
        #expect(names == ["file10.txt"])
    }

    @Test func packageIsNotAContainer() throws {
        let app = try FileItem(url: tmp.url.appendingPathComponent("App.app"))
        #expect(app.isDirectory)
        #expect(app.isPackage)
        #expect(!app.isContainer)
        #expect(app.size == nil)
    }

    @Test func symlinkToFolderIsAContainer() throws {
        let link = tmp.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tmp.url.appendingPathComponent("alpha"))
        let item = try FileItem(url: link)
        #expect(item.isSymbolicLink)
        #expect(item.isContainer)
    }

    @Test func baseNameDropsExtensionForFilesOnly() throws {
        #expect(try FileItem(url: tmp.url.appendingPathComponent("file2.txt")).baseName == "file2")
        #expect(try FileItem(url: tmp.url.appendingPathComponent("alpha")).baseName == "alpha")
    }
}

@Suite struct ListingPerformanceTests {
    @Test func bigFolderListsQuickly() throws {
        let tmp = TempDir()
        for i in 0..<5000 {
            FileManager.default.createFile(atPath: tmp.url.appendingPathComponent("file-\(i).txt").path, contents: nil)
        }
        let start = Date()
        let items = try DirectoryListing.load(tmp.url, options: ListingOptions())
        let elapsed = Date().timeIntervalSince(start)
        #expect(items.count == 5000)
        #expect(items[1].name == "file-1.txt" && items[2].name == "file-2.txt", "numeric order")
        // Debug build; release is ~3x faster. Generous bound to catch regressions only.
        #expect(elapsed < 1.0, "listing 5000 entries took \(elapsed)s")
    }

    @Test func fastPathMatchesResourceValues() throws {
        let tmp = TempDir()
        tmp.file("a.txt", "hello")
        tmp.dir("Pkg.app/Contents")
        tmp.file(".dot")
        let fast = try DirectoryListing.entries(of: tmp.url).sorted { $0.name < $1.name }
        for item in fast {
            let slow = try FileItem(url: item.url)
            #expect(item.isContainer == slow.isContainer, "\(item.name)")
            #expect(item.isPackage == slow.isPackage, "\(item.name)")
            #expect(item.isHidden == slow.isHidden, "\(item.name)")
            #expect(item.size == slow.size, "\(item.name)")
            #expect(abs((item.modified ?? .distantPast).timeIntervalSince(slow.modified ?? .distantPast)) < 0.01)
        }
        #expect(fast.first { $0.name == "a.txt" }?.kind.isEmpty == false)
    }
}
