import Testing
@testable import FmanCore

private func taken(_ names: [String]) -> (String) -> Bool {
    let set = Set(names.map { $0.lowercased() })
    return { set.contains($0.lowercased()) }
}

@Test func copyNamesFollowFinder() {
    #expect(UniqueName.copyName(for: "report.txt", isFolder: false, taken: taken(["report.txt"])) == "report copy.txt")
    #expect(UniqueName.copyName(for: "report.txt", isFolder: false, taken: taken(["report.txt", "report copy.txt"])) == "report copy 2.txt")
    #expect(UniqueName.copyName(for: "report copy.txt", isFolder: false, taken: taken(["report copy.txt"])) == "report copy 2.txt")
    #expect(UniqueName.copyName(for: "Photos", isFolder: true, taken: taken(["Photos"])) == "Photos copy")
    #expect(UniqueName.copyName(for: "v1.2", isFolder: true, taken: taken([])) == "v1.2 copy")
    #expect(UniqueName.copyName(for: ".zshrc", isFolder: false, taken: taken([])) == ".zshrc copy")
    #expect(UniqueName.copyName(for: "a.tar.gz", isFolder: false, taken: taken([])) == "a.tar copy.gz")
}

@Test func numberedNamesForKeepBoth() {
    #expect(UniqueName.numberedName(for: "a.txt", isFolder: false, taken: taken([])) == "a.txt")
    #expect(UniqueName.numberedName(for: "a.txt", isFolder: false, taken: taken(["a.txt"])) == "a 2.txt")
    #expect(UniqueName.numberedName(for: "a.txt", isFolder: false, taken: taken(["A.TXT", "a 2.txt"])) == "a 3.txt")
}

@Test func newFolderNames() {
    #expect(UniqueName.newFolderName(taken: taken([])) == "untitled folder")
    #expect(UniqueName.newFolderName(taken: taken(["untitled folder"])) == "untitled folder 2")
}
