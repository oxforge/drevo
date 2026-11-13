import Testing
@testable import DrevoCore

@Suite struct GlobalHotkeyRuleTests {
    func problem(_ keys: String, command: String? = nil) throws -> String? {
        try GlobalHotkeyRule.problem(with: KeyCombo(parsing: keys)) { _ in command }
    }

    @Test func acceptsCombosWithCommandOrControl() throws {
        #expect(try problem("ctrl+opt+cmd+d") == nil)
        #expect(try problem("ctrl+opt+space") != nil) // reserved by macOS (input sources)
        #expect(try problem("ctrl+shift+e") == nil)
        #expect(try problem("opt+f12") == nil)
    }

    @Test func refusesKeysThatTypeText() throws {
        #expect(try problem("d")?.contains("typing") == true)
        #expect(try problem("opt+d")?.contains("typing") == true)
        #expect(try problem("shift+d")?.contains("typing") == true)
        #expect(try problem("f5")?.contains("typing") == true)
    }

    @Test func refusesSystemShortcuts() throws {
        #expect(try problem("cmd+space")?.contains("macOS") == true)
        #expect(try problem("cmd+tab")?.contains("macOS") == true)
        #expect(try problem("cmd+q")?.contains("macOS") == true)
    }

    @Test func refusesAShortcutOfADrevoCommand() throws {
        #expect(try problem("shift+cmd+p", command: "Command Palette…") == "⇧⌘P is Drevo’s shortcut for “Command Palette…”.")
    }
}
