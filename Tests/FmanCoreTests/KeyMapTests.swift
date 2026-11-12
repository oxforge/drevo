import Foundation
import Testing
@testable import FmanCore

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
    #expect(map.keys(for: .copyToOtherPane).isEmpty, "bad key leaves the command unbound rather than half-applied")
    #expect(problems.map(\.command).sorted() == ["file.copyToOther", "nope"])
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
