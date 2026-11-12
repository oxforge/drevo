import Testing
@testable import FmanCore

@Test func bundleIdentifierIsStable() {
    #expect(Fman.bundleIdentifier == "tech.oxforge.fman")
}
