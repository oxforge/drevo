import Foundation
import Testing
@testable import DrevoCore

/// What the shortcut editor does with a recorded keystroke.
private func combo(_ s: String) -> KeyCombo { try! KeyCombo(parsing: s) }

private func context(global: String? = nil, menu: [String: String] = [:]) -> KeyRecording.Context {
    KeyRecording.Context(keyMap: KeyMap(), defaults: KeyMap(), globalHotkey: global.map(combo),
                         menuShortcuts: Dictionary(uniqueKeysWithValues: menu.map { (combo($0.key), $0.value) }))
}

private func refusal(_ outcome: KeyRecording.Outcome) -> String? {
    if case .refused(let message) = outcome { return message }
    return nil
}

@Test func replacingAKeyKeepsItsPlace() {
    let outcome = KeyRecording.record([combo("cmd+e")], for: .rename, slot: .replace(combo("f2")), in: context())
    #expect(outcome == .apply([.rename: [combo("cmd+e"), combo("cmd+r")]], note: nil))
}

@Test func theGlobalShortcutIsRefused() {
    let outcome = KeyRecording.record([combo("ctrl+opt+cmd+d")], for: .rename, slot: .add, in: context(global: "ctrl+opt+cmd+d"))
    #expect(refusal(outcome)?.contains("Show Drevo from any app") == true)
}

@Test func standardEditCommandsNeedCommandOrControl() {
    let plain = KeyRecording.record([combo("c")], for: .copy, slot: .add, in: context())
    #expect(refusal(plain)?.contains("text fields") == true)
    let withCommand = KeyRecording.record([combo("cmd+k")], for: .copy, slot: .add, in: context())
    #expect(withCommand == .apply([.copy: [combo("cmd+c"), combo("cmd+k")]], note: nil))
}

@Test func pathTypingKeysAreRefused() {
    #expect(refusal(KeyRecording.record([combo("/")], for: .swapPanes, slot: .add, in: context()))?.contains("path") == true)
    // ~ is typed with ⇧`: either reading starts a path.
    let tilde = KeyRecording.record([combo("shift+`"), combo("~")], for: .swapPanes, slot: .add, in: context())
    #expect(refusal(tilde)?.contains("path") == true)
    #expect(refusal(KeyRecording.record([combo("ctrl+/")], for: .swapPanes, slot: .add, in: context())) == nil)
}

@Test func fixedMenuShortcutsAreRefused() {
    let outcome = KeyRecording.record([combo("shift+cmd+w")], for: .swapPanes, slot: .add,
                                      in: context(menu: ["shift+cmd+w": "Close Window"]))
    #expect(refusal(outcome)?.contains("Close Window") == true)
}

@Test func aKeyTheCommandAlreadyHasChangesNothing() {
    #expect(KeyRecording.record([combo("cmd+r")], for: .rename, slot: .add, in: context()) == .unchanged)
    #expect(KeyRecording.record([combo("f2")], for: .rename, slot: .replace(combo("cmd+r")), in: context()) == .unchanged)
}

@Test func aKeyAnotherCommandHasIsMovedOnlyWhenConfirmed() {
    let outcome = KeyRecording.record([combo("cmd+d")], for: .rename, slot: .add, in: context())
    guard case .taken(let message, let changes, let note) = outcome else {
        Issue.record("expected .taken, got \(outcome)")
        return
    }
    #expect(message.contains("Duplicate"))
    #expect(changes == [.rename: [combo("f2"), combo("cmd+r"), combo("cmd+d")], .duplicate: []])
    #expect(note == nil)
}

@Test func everyReadingOfTheKeystrokeIsChecked() {
    // ⇧1 reads as "shift+1" and as "!", Run Shell Command's key.
    let outcome = KeyRecording.record([combo("shift+1"), combo("!")], for: .swapPanes, slot: .add, in: context())
    guard case .taken(let message, let changes, _) = outcome else {
        Issue.record("expected .taken, got \(outcome)")
        return
    }
    #expect(message.contains("Run Shell Command"))
    #expect(changes == [.swapPanes: [combo("cmd+u"), combo("shift+1")], .runCommand: [combo("opt+cmd+r")]])
}

@Test func plainKeysSayTheyWorkInTheFileListOnly() {
    let letter = KeyRecording.record([combo("h")], for: .levelUp, slot: .add, in: context())
    guard case .apply(let changes, let note?) = letter else {
        Issue.record("expected .apply with a note, got \(letter)")
        return
    }
    #expect(changes == [.levelUp: [combo("left"), combo("h")]])
    #expect(note.contains("file list") && note.contains("filter"))
    let named = KeyRecording.record([combo("pagedown")], for: .swapPanes, slot: .add, in: context())
    guard case .apply(_, let namedNote?) = named else {
        Issue.record("expected .apply with a note, got \(named)")
        return
    }
    #expect(namedNote.contains("file list") && !namedNote.contains("filter"))
}

@Test func entriesThatMatchTheDefaultAreRemoved() throws {
    var file = try KeyBindingsFile(data: Data(#"{ "file.rename": "f9", "_comment": "x" }"#.utf8))
    file.apply([.rename: KeyMap().keys(for: .rename), .duplicate: []], defaults: KeyMap())
    var map = KeyMap()
    #expect(try map.applyOverrides(json: file.data).isEmpty)
    #expect(map.overridden == [.duplicate])
    #expect(map.keys(for: .duplicate).isEmpty)
}

@Test func searchMatchesTitlesIdsAndKeys() throws {
    let spec = try #require(CommandRegistry.spec(.rename))
    let keys = [combo("f2"), combo("cmd+r")]
    for query in ["ren", "RENAME", "file.rename", "⌘R", "cmd+r", "f2", "  F2 "] {
        #expect(spec.matches(query, keys: keys), "\(query)")
    }
    for query in ["⌘D", "cmd+d", "f3", "duplicate"] {
        #expect(!spec.matches(query, keys: keys), "\(query)")
    }
    #expect(spec.matches("", keys: keys))
}

// MARK: The Return-key setting moves Return

private func renamesMode() -> KeyMap {
    var map = KeyMap()
    map.applyReturnRenames()
    return map
}

/// The key map Drevo loads: defaults for the setting, then the file.
private func loaded(_ file: KeyBindingsFile, renames: Bool) throws -> KeyMap {
    var map = renames ? renamesMode() : KeyMap()
    #expect(try map.applyOverrides(json: file.data).isEmpty)
    return map
}

@Test func returnMoveBackKeepsReturnBoundWhenOpenWasEdited() throws {
    var file = KeyBindingsFile()
    file.set([combo("cmd+down"), combo("cmd+o")], for: .open)
    let before = try loaded(file, renames: true)
    file.apply(KeyRecording.movingReturn(to: .open, in: before), defaults: KeyMap())
    let after = try loaded(file, renames: false)
    #expect(after.command(for: combo("return")) == .open)
    #expect(after.keys(for: .open) == [combo("return"), combo("cmd+down"), combo("cmd+o")])
    #expect(after.keys(for: .rename) == [combo("f2"), combo("cmd+r")])
    #expect(after.overridden == [.open])
}

@Test func returnMoveTakesReturnFromAnyCommand() throws {
    var file = KeyBindingsFile()
    file.set([combo("cmd+down")], for: .open)
    file.set([combo("return"), combo("space")], for: .quickLook)
    let before = try loaded(file, renames: false)
    file.apply(KeyRecording.movingReturn(to: .open, in: before), defaults: KeyMap())
    let after = try loaded(file, renames: false)
    #expect(after.keys(for: .quickLook) == [combo("space")])
    #expect(after.command(for: combo("return")) == .open)
}

@Test func returnMoveWithNothingSavedWritesNothing() throws {
    var file = KeyBindingsFile()
    file.apply(KeyRecording.movingReturn(to: .rename, in: KeyMap()), defaults: renamesMode())
    #expect(file.isEmpty)
    file.apply(KeyRecording.movingReturn(to: .open, in: renamesMode()), defaults: KeyMap())
    #expect(file.isEmpty)
}
