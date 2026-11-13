import AppKit
import Foundation
import Testing
@testable import DrevoCore
@testable import DrevoUI

/// The shortcut editor's saves: keybindings.json in a scratch folder, never the user's.
@MainActor
@Suite(.serialized) struct KeyBindingsSaveTests {
    let fx = Fixture()
    var overrides: URL { fx.url.appendingPathComponent("drevo/keybindings.json") }

    func combo(_ s: String) -> KeyCombo { try! KeyCombo(parsing: s) }

    func environment(file: String? = nil) -> AppEnvironment {
        if let file { fx.file("drevo/keybindings.json", file) }
        let base = testEnvironment(trash: fx.url.appendingPathComponent(".T"))
        return AppEnvironment(preferences: .ephemeral(), opener: base.opener, overridesURL: overrides,
                              operations: base.operations, shellSetup: base.shellSetup)
    }

    func written() throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: overrides)) as? NSDictionary)
    }

    /// Gives the file a modification date the environment hasn't seen, like an edit made later.
    func touch(_ contents: String) throws {
        try Data(contents.utf8).write(to: overrides)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: overrides.path)
    }

    @Test func savedChangesGoToTheFileAndApplyAtOnce() throws {
        let env = environment(file: #"{ "_comment": "mine", "pane.swap": null }"#)
        var announced = 0
        let token = NotificationCenter.default.addObserver(forName: AppEnvironment.keyMapDidChange, object: env, queue: nil) { _ in announced += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        try env.saveKeyChanges([.rename: [combo("f9")]])
        #expect(env.keyMap.keys(for: .rename) == [combo("f9")])
        #expect(announced == 1)
        let file = try written()
        #expect(file["file.rename"] as? [String] == ["f9"])
        #expect(file["_comment"] as? String == "mine")
        #expect(file["pane.swap"] is NSNull)
    }

    @Test func savingTheDefaultsWritesNoFile() throws {
        let env = environment()
        try env.saveKeyChanges([.rename: KeyMap().keys(for: .rename)])
        #expect(!FileManager.default.fileExists(atPath: overrides.path))
    }

    @Test func resettingACommandRemovesItsEntry() throws {
        let env = environment(file: #"{ "file.rename": "f9", "pane.swap": null }"#)
        try env.resetKeys(for: .rename)
        #expect(env.keyMap.keys(for: .rename) == KeyMap().keys(for: .rename))
        let file = try written()
        #expect(file["file.rename"] == nil)
        #expect(file["pane.swap"] is NSNull)
    }

    @Test func anUnreadableFileIsNeverOverwrittenByAnEdit() throws {
        let env = environment(file: "{ nope")
        #expect(env.keyBindingsFileError != nil)
        #expect(throws: (any Error).self) { try env.saveKeyChanges([.rename: [combo("f9")]]) }
        #expect(try String(contentsOf: overrides, encoding: .utf8) == "{ nope")
        #expect(env.keyMap.keys(for: .rename) == KeyMap().keys(for: .rename))
    }

    @Test func savingKeepsASymlinkedFile() throws {
        // keybindings.json kept in a dotfiles folder and linked into place.
        let real = fx.file("dotfiles/keybindings.json", #"{ "_comment": "mine" }"#)
        try FileManager.default.createDirectory(at: overrides.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: overrides, withDestinationURL: real)
        let env = environment()
        try env.saveKeyChanges([.rename: [combo("f9")]])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: overrides.path) == real.path)
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: real)) as? NSDictionary)
        #expect(saved == ["_comment": "mine", "file.rename": ["f9"]])
    }

    @Test func aFileThatCantBeOpenedIsNeverOverwritten() throws {
        fx.file("drevo/keybindings.json", #"{ "file.rename": "f9" }"#)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: overrides.path) // write-only
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: overrides.path) }
        let env = environment()
        #expect(env.keyBindingsFileError != nil)
        #expect(throws: (any Error).self) { try env.saveKeyChanges([.duplicate: [combo("f10")]]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: overrides.path)
        #expect(try String(contentsOf: overrides, encoding: .utf8) == #"{ "file.rename": "f9" }"#)
    }

    @Test func resetAllReplacesAnUnreadableFile() throws {
        let env = environment(file: "{ nope")
        try env.resetAllKeys()
        #expect(env.keyBindingsFileError == nil)
        #expect(try written().count == 0)
    }

    @Test func withoutAFileEditsStayInMemory() throws {
        let base = testEnvironment(trash: fx.url.appendingPathComponent(".T"))
        try base.saveKeyChanges([.rename: [combo("f9")]])
        #expect(base.keyMap.keys(for: .rename) == [combo("f9")])
        try base.resetKeys(for: .rename)
        #expect(base.keyMap.keys(for: .rename) == KeyMap().keys(for: .rename))
    }

    @Test func theEditorsOwnSavesAreNotOutsideChanges() throws {
        let env = environment()
        try env.saveKeyChanges([.rename: [combo("f9")]])
        #expect(env.reloadKeyMapIfFileChanged() == nil)
        try touch(#"{ "file.rename": "f10", "nope": "f1" }"#)
        let problems = try #require(env.reloadKeyMapIfFileChanged())
        #expect(problems.contains { $0.contains("nope") })
        #expect(env.keyMap.keys(for: .rename) == [combo("f10")])
        #expect(env.reloadKeyMapIfFileChanged() == nil)
    }

    @Test func flippingTheReturnSettingMovesReturn() throws {
        let env = environment(file: #"{ "file.rename": ["f2", "cmd+r", "cmd+e"] }"#)
        env.preferences.returnRenames = true
        #expect(env.keyMap.command(for: combo("return")) == .rename)
        #expect(env.keyMap.keys(for: .open) == [combo("cmd+down")])
        #expect(try written()["file.rename"] as? [String] == ["return", "f2", "cmd+r", "cmd+e"])
        #expect(try written()["nav.open"] == nil)

        env.preferences.returnRenames = false
        #expect(env.keyMap.command(for: combo("return")) == .open)
        #expect(try written()["file.rename"] as? [String] == ["f2", "cmd+r", "cmd+e"])
    }
}
