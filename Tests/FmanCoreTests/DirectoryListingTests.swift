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
