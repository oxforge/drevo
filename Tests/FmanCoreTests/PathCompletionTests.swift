import Foundation
import Testing
@testable import FmanCore

@Suite struct PathCompletionTests {
    let tmp = TempDir()
    init() {
        tmp.dir("Documents")
        tmp.dir("Downloads")
        tmp.dir("Desktop")
        tmp.dir(".config")
        tmp.file("Doc.txt")
    }

    @Test func expandsTilde() {
        #expect(PathCompletion.expand("~/x", home: "/Users/me") == "/Users/me/x")
        #expect(PathCompletion.expand("~", home: "/Users/me") == "/Users/me")
        #expect(PathCompletion.expand("sub", relativeTo: URL(fileURLWithPath: "/base")) == "/base/sub")
    }

    @Test func foldersOnlyCaseInsensitive() {
        let c = PathCompletion.candidates(for: "~/do", home: tmp.url.path)
        #expect(c == ["~/Documents/", "~/Downloads/"])
    }

    @Test func listsChildrenAfterSlash() {
        let c = PathCompletion.candidates(for: tmp.url.path + "/", home: "/nowhere")
        #expect(c.map { ($0 as NSString).lastPathComponent } == ["Desktop", "Documents", "Downloads"])
    }

    @Test func hiddenOnlyWhenTypedOrEnabled() {
        #expect(PathCompletion.candidates(for: "~/.c", home: tmp.url.path) == ["~/.config/"])
        #expect(PathCompletion.candidates(for: "~/", home: tmp.url.path).count == 3)
        #expect(PathCompletion.candidates(for: "~/", showHidden: true, home: tmp.url.path).count == 4)
    }

    @Test func bareTildeListsHomeFoldersInTildeForm() {
        let c = PathCompletion.candidates(for: "~", home: tmp.url.path)
        #expect(c == ["~/Desktop/", "~/Documents/", "~/Downloads/"])
        #expect(PathCompletion.complete("~", candidates: c) == "~/D")
        // The current folder plays no part, even when it has matching names.
        let base = tmp.dir("Documents/elsewhere")
        #expect(PathCompletion.candidates(for: "~", relativeTo: base, home: tmp.url.path) == c)
    }

    @Test func bareTildeWithOneFolderCompletesToIt() {
        let home = TempDir()
        home.dir("only")
        let c = PathCompletion.candidates(for: "~", home: home.url.path)
        #expect(c == ["~/only/"])
        #expect(PathCompletion.complete("~", candidates: c) == "~/only/")
        let expanded = PathCompletion.expand(c.first ?? "", relativeTo: URL(fileURLWithPath: "/base"), home: home.url.path)
        #expect(expanded == home.url.path + "/only/")
    }

    @Test func spacesAroundTheInputAreIgnored() {
        let home = tmp.url.path
        #expect(PathCompletion.candidates(for: "~/do ", home: home) == ["~/Documents/", "~/Downloads/"])
        #expect(PathCompletion.candidates(for: "  ~/do", home: home) == ["~/Documents/", "~/Downloads/"])
        #expect(PathCompletion.candidates(for: "~ ", home: home) == ["~/Desktop/", "~/Documents/", "~/Downloads/"])
        #expect(PathCompletion.candidates(for: "~/ ", home: home) == ["~/Desktop/", "~/Documents/", "~/Downloads/"])
        #expect(PathCompletion.candidates(for: "do ", relativeTo: tmp.url, home: "/nowhere") == ["Documents/", "Downloads/"])
        #expect(PathCompletion.candidates(for: "  ", relativeTo: tmp.url, home: "/nowhere") == ["Desktop/", "Documents/", "Downloads/"])
        #expect(PathCompletion.complete("  ~/d", candidates: ["~/Documents/", "~/Downloads/"]) == "~/Do")
    }

    @Test func spaceInsideANameIsKept() {
        tmp.dir("My Folder")
        tmp.dir("My Files")
        let home = tmp.url.path
        #expect(PathCompletion.candidates(for: "~/My F", home: home) == ["~/My Files/", "~/My Folder/"])
        #expect(PathCompletion.candidates(for: "~/My ", home: home) == ["~/My Files/", "~/My Folder/"])
        #expect(PathCompletion.complete("~/My ", candidates: ["~/My Files/", "~/My Folder/"]) == "~/My F")
    }

    @Test func completeUsesCommonPrefix() {
        #expect(PathCompletion.complete("~/d", candidates: ["~/Documents/", "~/Downloads/"]) == "~/Do")
        #expect(PathCompletion.complete("~/Doc", candidates: ["~/Documents/"]) == "~/Documents/")
        #expect(PathCompletion.complete("~/Do", candidates: ["~/Documents/", "~/Downloads/"]) == nil)
        #expect(PathCompletion.complete("~/x", candidates: []) == nil)
    }
}
