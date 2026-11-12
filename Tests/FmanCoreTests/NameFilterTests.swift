import Foundation
import Testing
@testable import FmanCore

struct NameFilterTests {
    @Test func plainTextMatchesAnywhereIgnoringCase() {
        let f = NameFilter("REP")
        #expect(f.matches("report.txt"))
        #expect(f.matches("my-Repo"))
        #expect(!f.matches("notes.md"))
    }

    @Test func starPatternMustMatchTheWholeName() {
        let f = NameFilter("*.png")
        #expect(f.matches("shot.png"))
        #expect(f.matches("Shot.PNG"))
        #expect(!f.matches("shot.png.txt"))
        #expect(!f.matches("png-notes"))
    }

    @Test func starAtTheEndMatchesAPrefix() {
        let f = NameFilter("img_*")
        #expect(f.matches("img_001.jpg"))
        #expect(!f.matches("old_img_001.jpg"))
    }

    @Test func questionMarkIsExactlyOneCharacter() {
        let f = NameFilter("file?.txt")
        #expect(f.matches("file1.txt"))
        #expect(!f.matches("file10.txt"))
        #expect(!f.matches("file.txt"))
    }

    @Test func starsOnBothSidesActLikeContains() {
        let f = NameFilter("*draft*")
        #expect(f.matches("Draft 2.pages"))
        #expect(f.matches("old-draft"))
        #expect(!f.matches("final.pages"))
    }

    @Test func bracketsAreOrdinaryCharacters() {
        #expect(NameFilter("[1]").matches("photo [1].jpg"))
        #expect(!NameFilter("[1]").matches("photo 1.jpg"))
        #expect(NameFilter("*[1].jpg").matches("photo [1].jpg"))
    }

    @Test func accentsAreIgnored() {
        #expect(NameFilter("cafe*").matches("Café.txt"))
        #expect(NameFilter("CAFÉ").matches("cafe.txt"))
    }

    @Test func emptyFilterMatchesEverything() {
        #expect(NameFilter("").isEmpty)
        #expect(NameFilter("  ").isEmpty)
        #expect(NameFilter("").matches("anything"))
    }

    @Test func listingAppliesWildcards() throws {
        let tmp = TempDir()
        for name in ["a.png", "b.PNG", "c.png.bak", "d.jpg"] {
            FileManager.default.createFile(atPath: tmp.url.appendingPathComponent(name).path, contents: Data())
        }
        let names = try DirectoryListing.load(tmp.url, options: ListingOptions(filter: "*.png")).map(\.name)
        #expect(names == ["a.png", "b.PNG"])
    }
}
