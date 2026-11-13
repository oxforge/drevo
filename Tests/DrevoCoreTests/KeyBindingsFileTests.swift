import Foundation
import Testing
@testable import DrevoCore

/// keybindings.json as the editor changes it: only the entries it touches change.
private let handWritten = """
{
  "_comment": "my notes",
  "_example_vim_style": { "nav.levelUp": ["left", "h"] },
  "nav.levelUp": ["left", "h"],
  "pane.swap": null,
  "nope": "f1",
  "file.copyToOther": "cmd+banana"
}
"""

private func object(_ data: Data) throws -> NSDictionary {
    try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
}

@Test func editingOneCommandKeepsCommentsAndOtherEntries() throws {
    var file = try KeyBindingsFile(data: Data(handWritten.utf8))
    file.set([.named(.f9), .char("e", .command)], for: .rename)
    let written = try object(file.data)
    #expect(written["file.rename"] as? [String] == ["f9", "cmd+e"])
    #expect(written["_comment"] as? String == "my notes")
    #expect(written["_example_vim_style"] as? NSDictionary == ["nav.levelUp": ["left", "h"]])
    #expect(written["nav.levelUp"] as? [String] == ["left", "h"])
    #expect(written["pane.swap"] is NSNull)
    #expect(written["nope"] as? String == "f1", "an unknown command stays for the user to fix")
    #expect(written["file.copyToOther"] as? String == "cmd+banana", "an unreadable key stays as written")
    #expect(written.count == 7)
}

@Test func removingACommandDropsOnlyItsEntry() throws {
    var file = try KeyBindingsFile(data: Data(handWritten.utf8))
    file.remove(.levelUp)
    let written = try object(file.data)
    #expect(written["nav.levelUp"] == nil)
    #expect(written.count == 5)
}

@Test func removeAllCommandsKeepsOnlyComments() throws {
    var file = try KeyBindingsFile(data: Data(handWritten.utf8))
    file.removeAllCommands()
    let written = try object(file.data)
    #expect(Set(written.allKeys as! [String]) == ["_comment", "_example_vim_style"])
}

@Test func unbindingIsWrittenAsAnEmptyList() throws {
    var file = KeyBindingsFile()
    file.set([], for: .swapPanes)
    var map = KeyMap()
    let problems = try map.applyOverrides(json: file.data)
    #expect(problems.isEmpty)
    #expect(map.keys(for: .swapPanes).isEmpty)
}

@Test func writtenFileReadsBackSortedWithCommentsFirst() throws {
    var file = try KeyBindingsFile(data: Data(#"{ "nav.levelUp": "h", "_comment": "notes" }"#.utf8))
    file.set([.named(.f9), .char("+", .command)], for: .rename)
    let text = String(decoding: file.data, as: UTF8.self)
    let comment = try #require(text.range(of: "_comment")).lowerBound
    let rename = try #require(text.range(of: "file.rename")).lowerBound
    let levelUp = try #require(text.range(of: "nav.levelUp")).lowerBound
    #expect(comment < rename && rename < levelUp)
    #expect(text.hasSuffix("}\n"))
    var map = KeyMap()
    #expect(try map.applyOverrides(json: file.data).isEmpty)
    #expect(map.keys(for: .rename) == [.named(.f9), .char("+", .command)])
}

@Test func missingOrBlankFileIsEmpty() throws {
    #expect(try KeyBindingsFile(data: Data()).isEmpty)
    #expect(try KeyBindingsFile(data: Data(" \n".utf8)).isEmpty)
    #expect(!(try KeyBindingsFile(data: Data(handWritten.utf8)).isEmpty))
}

@Test func unreadableFileIsAnError() {
    #expect(throws: (any Error).self) { try KeyBindingsFile(data: Data("{ nope".utf8)) }
    #expect(throws: (any Error).self) { try KeyBindingsFile(data: Data("[1, 2]".utf8)) }
}
