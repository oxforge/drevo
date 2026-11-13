import Foundation
import Testing
@testable import DrevoCore

@Test func parsesAndPrints() throws {
    let c = try KeyCombo(parsing: "cmd+shift+n")
    #expect(c == KeyCombo.char("n", [.command, .shift]))
    #expect(c.description == "⇧⌘N")
    #expect(c.configString == "shift+cmd+n")
    #expect(try KeyCombo(parsing: "F5").description == "F5")
    #expect(try KeyCombo(parsing: "opt+cmd+backspace").description == "⌥⌘⌫")
    #expect(try KeyCombo(parsing: "ctrl+opt+shift+cmd+k").description == "⌃⌥⇧⌘K")
    #expect(try KeyCombo(parsing: "tab").description == "⇥")
    #expect(try KeyCombo(parsing: "cmd+plus") == KeyCombo.char("+", [.command]))
    #expect(try KeyCombo(parsing: "cmd++") == KeyCombo.char("+", [.command]))
    #expect(try KeyCombo(parsing: "!") == KeyCombo.char("!"))
    #expect(try KeyCombo(parsing: "enter") == KeyCombo.named(.return))
}

@Test func rejectsGarbage() {
    #expect(throws: KeyCombo.ParseError.empty) { try KeyCombo(parsing: " ") }
    #expect(throws: KeyCombo.ParseError.unknownModifier("hyper")) { try KeyCombo(parsing: "hyper+k") }
    #expect(throws: KeyCombo.ParseError.unknownKey("banana")) { try KeyCombo(parsing: "cmd+banana") }
}

@Test func plainTypingKeysAreFlagged() throws {
    #expect(try KeyCombo(parsing: "!").isPlainTyping)
    #expect(try KeyCombo(parsing: "tab").isPlainTyping)
    #expect(try !KeyCombo(parsing: "f5").isPlainTyping)
    #expect(try !KeyCombo(parsing: "cmd+c").isPlainTyping)
}

@Test func codableAsString() throws {
    let data = try JSONEncoder().encode([KeyCombo.named(.f5)])
    #expect(String(data: data, encoding: .utf8) == "[\"f5\"]")
    #expect(try JSONDecoder().decode([KeyCombo].self, from: data) == [KeyCombo.named(.f5)])
}
