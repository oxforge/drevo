import Foundation
import Testing
@testable import DrevoCore

@Suite struct FileSearchTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("drevo-search-\(UUID().uuidString)").resolvingSymlinksInPath()
        for path in ["notes.txt", "a/notes-old.txt", "a/b/c/Deep Notes.md", "a/other.png", ".hidden/notes.txt",
                     "App.app/Contents/notes.txt", "a/.notes-secret", "pics/one.png", "pics/two.PNG"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/notes folder"), withIntermediateDirectories: true)
        // A link back up the tree must not send the walk round in circles.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("a/loop"), withDestinationURL: root)
    }

    func search(_ query: String, hidden: Bool = false, configure: (inout FileSearch) -> Void = { _ in }) -> (paths: [String], outcome: FileSearch.Outcome) {
        var s = FileSearch(root: root, query: query, showHidden: hidden)
        s.spotlight = nil
        s.batchInterval = 0
        configure(&s)
        var found: [FileItem] = []
        let outcome = s.run { found += $0 }
        let prefix = root.path + "/"
        return (found.map { String($0.url.path.dropFirst(prefix.count)) }, outcome)
    }

    @Test func findsNamesContainingTheTextAtAnyDepth() {
        let r = search("notes")
        #expect(Set(r.paths) == ["notes.txt", "a/notes-old.txt", "a/b/c/Deep Notes.md", "a/notes folder"])
        #expect(r.outcome == FileSearch.Outcome(found: 4))
        // Nearest first.
        #expect(r.paths.first == "notes.txt")
        #expect(r.paths.last == "a/b/c/Deep Notes.md")
    }

    @Test func wildcardsMatchTheWholeName() {
        #expect(Set(search("*.png").paths) == ["a/other.png", "pics/one.png", "pics/two.PNG"])
        #expect(search("on?.png").paths == ["pics/one.png"])
    }

    @Test func hiddenFilesAndFoldersOnlyWhenShown() {
        #expect(Set(search("notes", hidden: true).paths).isSuperset(of: [".hidden/notes.txt", "a/.notes-secret"]))
        #expect(!search("notes").paths.contains { $0.contains(".hidden") || $0.contains(".notes") })
    }

    @Test func doesNotLookInsidePackagesOrFollowLinks() {
        let r = search("notes", hidden: true)
        #expect(!r.paths.contains { $0.hasPrefix("App.app/") })
        #expect(!r.paths.contains { $0.hasPrefix("a/loop/") })
        // The package and the link themselves can be found.
        #expect(search("App").paths == ["App.app"])
        #expect(search("loop").paths == ["a/loop"])
    }

    @Test func anEmptyQueryFindsNothing() {
        #expect(search("  ").paths.isEmpty)
    }

    @Test func stopsAtTheLimitAndWhenCancelled() {
        let limited = search("notes") { $0.limit = 2 }
        #expect(limited.paths.count == 2)
        #expect(limited.outcome.truncated)

        var s = FileSearch(root: root, query: "notes", showHidden: false)
        s.spotlight = nil
        var batches = 0
        let outcome = s.run(isCancelled: { true }) { _ in batches += 1 }
        #expect(outcome.cancelled)
        #expect(batches == 0)
    }

    @Test func spotlightHitsComeFirstAndAreCheckedAndNotRepeated() {
        let rootPath = root.path
        let r = search("notes") { s in
            s.spotlight = { _, _, _ in
                ["\(rootPath)/a/b/c/Deep Notes.md",       // real: first
                 "\(rootPath)/a/other.png",                // doesn't match the query
                 "\(rootPath)/gone/notes.txt",             // no longer exists
                 "\(rootPath)/.hidden/notes.txt",          // hidden, not shown
                 "/etc/notes.txt"]                         // outside the folder
            }
        }
        #expect(r.paths.first == "a/b/c/Deep Notes.md")
        #expect(r.paths.count == 4)
        #expect(Set(r.paths) == ["notes.txt", "a/notes-old.txt", "a/b/c/Deep Notes.md", "a/notes folder"])
    }

    @Test func spotlightQueryEscapesWhatTheUserTyped() {
        #expect(Spotlight.predicate(for: "notes") == "kMDItemFSName == '*notes*'cd")
        #expect(Spotlight.predicate(for: "*.png") == "kMDItemFSName == '*.png'cd")
        #expect(Spotlight.predicate(for: "it's") == "kMDItemFSName == '*it\\'s*'cd")
    }
}
