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

    @Test func completeUsesCommonPrefix() {
        #expect(PathCompletion.complete("~/d", candidates: ["~/Documents/", "~/Downloads/"]) == "~/Do")
        #expect(PathCompletion.complete("~/Doc", candidates: ["~/Documents/"]) == "~/Documents/")
        #expect(PathCompletion.complete("~/Do", candidates: ["~/Documents/", "~/Downloads/"]) == nil)
        #expect(PathCompletion.complete("~/x", candidates: []) == nil)
    }
}
