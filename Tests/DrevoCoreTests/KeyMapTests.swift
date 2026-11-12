import Foundation
import Testing
@testable import DrevoCore

@Test func defaultsHaveNoConflicts() {
    #expect(KeyMap().conflicts.isEmpty)
}

@Test func defaultsAvoidSystemShortcuts() {
    for spec in CommandRegistry.all {
        for k in spec.defaultKeys {
            #expect(!SystemShortcuts.reserved.contains(k), "\(spec.id) uses reserved \(k)")
        }
    }
}

@Test func commandIDsAreUnique() {
    #expect(Set(CommandRegistry.all.map(\.id)).count == CommandRegistry.all.count)
}

@Test func lookupByKey() throws {
    let map = KeyMap()
    #expect(map.command(for: .named(.f5)) == .copyToOtherPane)
    #expect(map.command(for: try KeyCombo(parsing: "shift+cmd+c")) == .copyToOtherPane)
    #expect(map.command(for: .named(.tab)) == .nextPane)
    #expect(map.command(for: .char("!")) == .runCommand)
}

@Test func overridesReplaceUnbindAndReport() throws {
    var map = KeyMap()
    let json = """
    { "file.rename": "f9", "nav.levelUp": ["left", "h"], "pane.swap": null, "nope": "f1", "file.copyToOther": "cmd+banana" }
    """
    let problems = try map.applyOverrides(json: Data(json.utf8))
    #expect(map.keys(for: .rename) == [.named(.f9)])
    #expect(map.keys(for: .levelUp) == [.named(.left), .char("h")])
    #expect(map.keys(for: .swapPanes).isEmpty)
    #expect(map.keys(for: .copyToOtherPane) == KeyMap().keys(for: .copyToOtherPane), "a key that can't be read leaves the command as it was")
    #expect(problems.map(\.command).sorted() == ["file.copyToOther", "nope"])
    #expect(map.overridden == [.rename, .levelUp, .swapPanes])
}

@Test func typoInOverrideKeepsTheCurrentKeys() throws {
    var map = KeyMap()
    let defaults = map.keys(for: .rename)
    #expect(!defaults.isEmpty)
    let problems = try map.applyOverrides(json: Data(#"{ "file.rename": "f22" }"#.utf8))
    #expect(map.keys(for: .rename) == defaults)
    #expect(!map.overridden.contains(.rename))
    #expect(problems == [KeyMap.OverrideProblem(command: "file.rename", message: #"can't read key "f22""#)])
}

@Test func listOfOnlyUnreadableKeysKeepsTheCurrentKeys() throws {
    var map = KeyMap()
    map.applyReturnRenames()
    let current = map.keys(for: .rename)
    #expect(current.first == .named(.return), "the current keys, not the registry defaults")
    let problems = try map.applyOverrides(json: Data(#"{ "file.rename": ["f22", "cmd+banana"], "pane.swap": [7] }"#.utf8))
    #expect(map.keys(for: .rename) == current)
    #expect(map.keys(for: .swapPanes) == KeyMap().keys(for: .swapPanes), "a list without any key string is a mistake, not an unbind")
    #expect(map.overridden.isEmpty)
    #expect(problems.map(\.command) == ["file.rename", "file.rename", "pane.swap"])
}

@Test func nullAndEmptyListStillUnbind() throws {
    var map = KeyMap()
    #expect(!map.keys(for: .rename).isEmpty && !map.keys(for: .swapPanes).isEmpty)
    let problems = try map.applyOverrides(json: Data(#"{ "file.rename": [], "pane.swap": null }"#.utf8))
    #expect(map.keys(for: .rename).isEmpty)
    #expect(map.keys(for: .swapPanes).isEmpty)
    #expect(map.overridden == [.rename, .swapPanes])
    #expect(problems.isEmpty)
}

@Test func partlyReadableListAppliesWhatParsedAndReportsTheRest() throws {
    var map = KeyMap()
    let problems = try map.applyOverrides(json: Data(#"{ "file.rename": ["f22", "f9", 7] }"#.utf8))
    #expect(map.keys(for: .rename) == [.named(.f9)])
    #expect(map.overridden == [.rename])
    #expect(problems.map(\.command) == ["file.rename", "file.rename"])
    #expect(problems.first?.message == #"can't read key "f22""#)
}

@Test func overridesMustBeAnObject() {
    var map = KeyMap()
    #expect(throws: (any Error).self) { try map.applyOverrides(json: Data("[1]".utf8)) }
}

@Test func conflictsAreReported() throws {
    var map = KeyMap()
    try map.applyOverrides(json: Data(#"{ "file.rename": "f5" }"#.utf8))
    #expect(map.conflicts[.named(.f5)] == [.copyToOtherPane, .rename])
    #expect(map.command(for: .named(.f5)) == .rename, "the user's override wins")
}

@Test func returnRenamesMode() {
    var map = KeyMap()
    map.applyReturnRenames()
    #expect(map.command(for: .named(.return)) == .rename)
    #expect(map.keys(for: .open) == [KeyCombo.named(.down, [.command])])
    #expect(map.conflicts.isEmpty)
}

@Test func templateIsValidJSONAndRoundTrips() throws {
    let map = KeyMap()
    let text = map.templateJSON()
    var copy = KeyMap()
    let problems = try copy.applyOverrides(json: Data(text.utf8))
    #expect(problems.isEmpty)
    #expect(copy.bindings == map.bindings)
}

@Test func starterFileHasNoEffectAndNoProblems() throws {
    var map = KeyMap()
    let problems = try map.applyOverrides(json: Data(KeyMap.starterJSON.utf8))
    #expect(problems.isEmpty)
    #expect(map.bindings == KeyMap().bindings)
}
