import Testing
@testable import DrevoCore

@Suite struct GlobalHotkeyRuleTests {
    func problem(_ keys: String) throws -> String? {
        try GlobalHotkeyRule.problem(with: KeyCombo(parsing: keys))
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
}
