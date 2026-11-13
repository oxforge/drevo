import Foundation
import Testing
@testable import DrevoCore

@Suite struct CommandCompletionTests {
    let tmp = TempDir()
    init() {
        tmp.dir("admin")
        tmp.file("address book.txt")
        tmp.file("notes.md")
        tmp.file(".hidden")
        tmp.file("Sub/inner.txt")
        tmp.file("Sub/index.html")
    }

    func complete(_ line: String, at cursor: Int? = nil) -> CommandCompletion.Result {
        CommandCompletion.complete(line: line, cursor: cursor ?? (line as NSString).length,
                                   relativeTo: tmp.url, home: "/nowhere")
    }

    @Test func uniqueFileIsCompletedWithATrailingSpace() {
        let r = complete("cat no")
        #expect(r.range == NSRange(location: 4, length: 2))
        #expect(r.replacement == "notes.md ")
    }

    @Test func uniqueFolderEndsWithASlashAndNoSpace() {
        #expect(complete("ls adm").replacement == "admin/")
        #expect(complete("ls su").replacement == "Sub/", "matching ignores case, the name keeps its own")
    }

    @Test func severalMatchesExtendToTheirCommonPrefix() {
        #expect(complete("ls a").replacement == "ad")
        #expect(complete("ls Sub/in").replacement == nil)
    }

    @Test func nothingToExtendOffersTheChoices() {
        let r = complete("ls ad")
        #expect(r.replacement == nil)
        #expect(r.choices.map(\.title) == ["address book.txt", "admin"])
        #expect(r.choices.map(\.replacement) == ["address\\ book.txt ", "admin/"])
    }

    @Test func specialCharactersAreEscaped() {
        #expect(complete("cat addr").replacement == "address\\ book.txt ")
        #expect(complete("cat address\\ b").replacement == "address\\ book.txt ")
        #expect(complete("cat 'address b").replacement == "address\\ book.txt ", "an open quote is replaced too")
        #expect(complete("cat 'address b").range == NSRange(location: 4, length: 10))
    }

    @Test func pathsInsideFoldersKeepWhatWasTyped() {
        #expect(complete("cat Sub/inn").replacement == "Sub/inner.txt ")
        #expect(complete("cat \(tmp.url.path)/no").replacement == "\(tmp.url.path)/notes.md ")
    }

    @Test func tildeStaysATilde() {
        let r = CommandCompletion.complete(line: "ls ~/no", cursor: 7, relativeTo: URL(fileURLWithPath: "/"), home: tmp.url.path)
        #expect(r.replacement == "~/notes.md ")
    }

    @Test func hiddenFilesNeedADot() {
        #expect(complete("ls ").choices.map(\.title) == ["address book.txt", "admin", "notes.md", "Sub"])
        #expect(complete("ls .h").replacement == ".hidden ")
    }

    @Test func onlyTheWordBeforeTheCursorIsCompleted() {
        let r = complete("cat no | wc", at: 6)
        #expect(r.range == NSRange(location: 4, length: 2))
        #expect(r.replacement == "notes.md ")
        #expect(complete("echo x;cat no").range == NSRange(location: 11, length: 2), "; | & < > ( start a word")
    }

    @Test func noMatchGivesNothing() {
        let r = complete("ls zzz")
        #expect(r.replacement == nil)
        #expect(r.choices.isEmpty)
    }
}
