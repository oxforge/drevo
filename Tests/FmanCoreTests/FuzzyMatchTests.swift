import Testing
@testable import FmanCore

@Test func subsequenceMatches() {
    #expect(FuzzyMatch.match("cpo", in: "Copy to Other Pane") != nil)
    #expect(FuzzyMatch.match("xyz", in: "Copy to Other Pane") == nil)
    #expect(FuzzyMatch.match("", in: "anything")?.score == 0)
}

@Test func wordStartsRankHigher() {
    let ranked = FuzzyMatch.rank("nf", ["Info Panel", "New Folder", "Unfold"]) { $0 }.map(\.item)
    #expect(ranked.first == "New Folder")
}

@Test func positionsPointAtMatchedCharacters() {
    #expect(FuzzyMatch.match("nf", in: "New Folder")?.positions == [0, 4])
}
