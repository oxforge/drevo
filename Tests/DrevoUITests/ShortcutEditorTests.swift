import AppKit
import Foundation
import Testing
@testable import DrevoCore
@testable import DrevoUI

/// Settings ▸ Keys: the editor's model and its keycap recorder. keybindings.json lives in
/// a scratch folder.
@MainActor
@Suite(.serialized) struct ShortcutEditorTests {
    let fx = Fixture()
    let prompts = ScriptedPrompts()
    var overrides: URL { fx.url.appendingPathComponent("drevo/keybindings.json") }

    func combo(_ s: String) -> KeyCombo { try! KeyCombo(parsing: s) }

    func editor(file: String? = nil) -> ShortcutEditorModel {
        if let file { fx.file("drevo/keybindings.json", file) }
        let base = testEnvironment(trash: fx.url.appendingPathComponent(".T"), prompts: prompts)
        let env = AppEnvironment(preferences: .ephemeral(), opener: base.opener, overridesURL: overrides,
                                 operations: base.operations, shellSetup: base.shellSetup)
        return ShortcutEditorModel(env: env)
    }

    func written() throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: overrides)) as? NSDictionary)
    }

    @Test func recordingAFreeKeySavesIt() throws {
        let model = editor()
        #expect(model.record([combo("cmd+e")], for: .rename, slot: .add))
        #expect(model.keys(for: .rename) == [combo("f2"), combo("cmd+r"), combo("cmd+e")])
        #expect(model.isChanged(.rename))
        #expect(model.env.keyMap.command(for: combo("cmd+e")) == .rename)
        #expect(try written()["file.rename"] as? [String] == ["f2", "cmd+r", "cmd+e"])
    }

    @Test func aRefusedKeyKeepsRecordingAndSavesNothing() {
        let model = editor()
        #expect(!model.record([combo("cmd+space")], for: .rename, slot: .add), "recording goes on")
        #expect(model.notice?.command == .rename)
        #expect(model.notice?.message.contains("macOS") == true)
        #expect(!FileManager.default.fileExists(atPath: overrides.path))
        model.recordingEnded(for: .rename)
        #expect(model.notice == nil)
    }

    @Test func aTakenKeyMovesOnlyOnUseHere() throws {
        let model = editor()
        #expect(model.record([combo("cmd+d")], for: .rename, slot: .add))
        #expect(model.notice?.isQuestion == true)
        #expect(model.notice?.message.contains("Duplicate") == true)
        #expect(model.keys(for: .duplicate) == [combo("cmd+d")], "nothing moves before the answer")

        model.cancelNotice()
        #expect(model.notice == nil)
        #expect(model.keys(for: .duplicate) == [combo("cmd+d")])

        #expect(model.record([combo("cmd+d")], for: .rename, slot: .add))
        model.useHere()
        #expect(model.notice == nil)
        #expect(model.keys(for: .duplicate).isEmpty)
        #expect(model.keys(for: .rename).last == combo("cmd+d"))
        #expect(try written()["file.duplicate"] as? [String] == [])
    }

    @Test func aPlainKeyLeavesANote() {
        let model = editor()
        #expect(model.record([combo("h")], for: .levelUp, slot: .add))
        #expect(model.notice?.isQuestion == false)
        #expect(model.notice?.message.contains("file list") == true)
        #expect(model.keys(for: .levelUp) == [combo("left"), combo("h")])
    }

    @Test func removingAndResettingKeys() throws {
        let model = editor()
        model.remove(combo("cmd+r"), from: .rename)
        #expect(model.keys(for: .rename) == [combo("f2")])
        #expect(try written()["file.rename"] as? [String] == ["f2"])
        model.reset(.rename)
        #expect(!model.isChanged(.rename))
        #expect(try written()["file.rename"] == nil)
    }

    @Test func resetAllAsksFirst() throws {
        let model = editor(file: #"{ "_comment": "mine", "file.rename": "f9" }"#)
        prompts.confirmAnswer = false
        model.resetAll()
        #expect(prompts.confirmations.count == 1)
        #expect(model.keys(for: .rename) == [combo("f9")])
        prompts.confirmAnswer = true
        model.resetAll()
        #expect(model.keys(for: .rename) == KeyMap().keys(for: .rename))
        #expect(try written() == ["_comment": "mine"])
    }

    @Test func anUnreadableFileDisablesEditing() throws {
        let model = editor(file: "{ nope")
        #expect(!model.canEdit)
        #expect(model.fileError != nil)
        #expect(!model.record([combo("cmd+e")], for: .rename, slot: .add))
        #expect(try String(contentsOf: overrides, encoding: .utf8) == "{ nope")
        prompts.confirmAnswer = true
        model.resetAll()
        #expect(model.canEdit)
    }

    @Test func searchAndChangedFilterTheList() {
        let model = editor(file: #"{ "file.rename": "f9" }"#)
        model.query = "f9"
        #expect(model.sections.map(\.category) == [.file])
        #expect(model.sections.first?.commands.map(\.id) == [.rename])
        model.query = ""
        model.changedOnly = true
        #expect(model.changedCount == 1)
        #expect(model.sections.flatMap(\.commands).map(\.id) == [.rename])
        model.changedOnly = false
        #expect(model.sections.flatMap(\.commands).count == CommandRegistry.all.count)
    }

    @Test func outsideEditsRefreshTheEditor() throws {
        let model = editor()
        fx.file("drevo/keybindings.json", #"{ "file.rename": "f10" }"#)
        model.env.reloadKeyMap()
        #expect(model.keys(for: .rename) == [combo("f10")])
    }

    @Test func fixedMenuShortcutsMatchTheMenu() {
        let menu = MainMenu.build(keyMap: KeyMap())
        var found: [KeyCombo: String] = [:]
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let sub = item.submenu { walk(sub) }
                guard item.representedObject == nil, !item.keyEquivalent.isEmpty else { continue }
                var mods = KeyCombo.Modifiers(item.keyEquivalentModifierMask)
                let key = item.keyEquivalent
                if key != key.lowercased() { mods.insert(.shift) }
                found[KeyCombo(.character(key.lowercased()), mods)] = item.title
            }
        }
        walk(menu)
        #expect(found == MainMenu.fixedShortcuts)
    }

    // MARK: Keycap recorder

    @Test func keycapRecordsEveryReadingAndCancelsOnEsc() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        let button = KeyRecorderButton(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        window.contentView!.addSubview(button)
        button.restingTitle = "⌘R"
        var recorded: [[KeyCombo]] = []
        var ended = 0
        button.onKeystroke = { recorded.append(KeyCombo.candidates(for: $0)); return true }
        button.onEnd = { ended += 1 }
        #expect(button.title == "⌘R")

        button.toggleRecording(nil)
        #expect(button.title == "Press keys…")
        // Tab doesn't move focus while recording: it's recorded.
        button.keyDown(with: key(KeyCode.tab, "\t", [], window: window))
        #expect(recorded == [[.named(.tab)]])
        #expect(button.title == "⌘R")

        button.toggleRecording(nil)
        #expect(button.performKeyEquivalent(with: key(KeyCode.one, "1", [.command, .shift], window: window)))
        #expect(recorded.count == 2)

        button.toggleRecording(nil)
        button.keyDown(with: key(53, "\u{1b}", [], window: window))
        #expect(recorded.count == 2, "Esc cancels")
        #expect(button.title == "⌘R")
        #expect(ended == 3)
    }
}
