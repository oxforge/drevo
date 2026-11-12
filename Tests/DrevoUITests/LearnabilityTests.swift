import AppKit
import Testing
@testable import DrevoCore
@testable import DrevoUI

@MainActor
@Suite(.serialized) struct LearnabilityTests {
    let fx = Fixture()

    init() {
        fx.file("a.txt")
        fx.dir("Folder")
    }

    @Test func keyHintsShowFKeysAndRunCommands() {
        let wc = makeWindow([fx.url, fx.url])
        #expect(KeyHintBar.displayKey(.copyToOtherPane, keyMap: wc.env.keyMap) == "F5")
        #expect(KeyHintBar.displayKey(.nextPane, keyMap: wc.env.keyMap) == "⇥")
        #expect(KeyHintBar.displayKey(.commandPalette, keyMap: wc.env.keyMap) == "⇧⌘P")
        #expect(wc.keyHints.shownCommands.first == .nextPane)
        wc.keyHints.onCommand?(.nextPane)
        #expect(wc.paneGroup.activeIndex == 1)
    }

    @Test func hintsFollowRebinding() throws {
        let env = testEnvironment(trash: fx.url.appendingPathComponent(".T"))
        let wc = makeWindow([fx.url, fx.url], env: env)
        var map = env.keyMap
        try map.applyOverrides(json: Data(#"{ "file.copyToOther": "cmd+k" }"#.utf8))
        wc.keyHints.reload(keyMap: map)
        #expect(KeyHintBar.displayKey(.copyToOtherPane, keyMap: map) == "⌘K")
    }

    /// The sort button's tooltip names the keys as they are bound now, not the defaults.
    @Test func sortTooltipFollowsRebinding() throws {
        #expect(SortButton.toolTip(keyMap: KeyMap()) == "Sort order (⌃⌥⌘1 Name, ⌃⌥⌘2 Kind, ⌃⌥⌘5 Date Modified, ⌃⌥⌘6 Size)")
        var none = KeyMap()
        for id in [CommandID.sortByName, .sortByKind, .sortByModified, .sortBySize] { none.set([], for: id) }
        #expect(SortButton.toolTip(keyMap: none) == "Sort order")

        // A window whose environment reads its key bindings from a scratch file.
        let overrides = fx.url.appendingPathComponent("keybindings.json")
        let base = testEnvironment(trash: fx.url.appendingPathComponent(".T"))
        let env = AppEnvironment(preferences: .ephemeral(), opener: base.opener, overridesURL: overrides,
                                 operations: base.operations, shellSetup: base.shellSetup)
        let wc = makeWindow([fx.url, fx.url], env: env)
        let button = wc.paneGroup.panes[1].sortButton
        #expect(button.toolTip == SortButton.toolTip(keyMap: KeyMap()))

        try Data(#"{ "view.sortByName": "cmd+k", "view.sortByKind": null, "view.sortByCreated": "ctrl+opt+cmd+7" }"#.utf8).write(to: overrides)
        env.reloadKeyMap()
        #expect(button.toolTip == "Sort order (⌘K Name, ⌃⌥⌘5 Date Modified, ⌃⌥⌘7 Date Created, ⌃⌥⌘6 Size)")
        // A pane added later shows them too.
        wc.perform(.addPane)
        #expect(wc.paneGroup.panes[2].sortButton.toolTip == button.toolTip)
    }

    @Test func paletteFindsAndRunsCommands() throws {
        let wc = makeWindow([fx.url, fx.url])
        wc.perform(.commandPalette)
        let palette = try #require(CommandPalette.current)
        palette.update(query: "swap")
        #expect(palette.results.first?.id == .swapPanes)
        palette.update(query: "hidden")
        #expect(palette.results.first?.id == .toggleHidden)
        let before = wc.env.preferences.showHidden
        palette.runSelected()
        #expect(wc.env.preferences.showHidden != before)
        #expect(CommandPalette.current == nil)
    }

    @Test func paletteDoesNotRunDisabledCommands() throws {
        let wc = makeWindow([fx.url, fx.url])
        wc.perform(.commandPalette)
        let palette = try #require(CommandPalette.current)
        palette.update(query: "stop running")
        #expect(palette.results.first?.id == .stopCommand)
        palette.runSelected()
        #expect(CommandPalette.current != nil, "nothing is running, so Stop is disabled and the palette stays")
        palette.close()
    }

    @Test func shortcutsCheatSheetListsEverything() {
        let text = ShortcutsWindow.text(keyMap: KeyMap()).string
        for spec in CommandRegistry.all { #expect(text.contains(spec.title)) }
        #expect(text.contains("F5"))
    }

    @Test func menusShowKeyEquivalentsFromKeymap() throws {
        let menu = MainMenu.build(keyMap: KeyMap())
        func find(_ title: String) -> NSMenuItem? {
            for top in menu.items { if let i = top.submenu?.items.first(where: { $0.title == title }) { return i } }
            return nil
        }
        let copy = try #require(find("Copy to Other Pane"))
        #expect(copy.keyEquivalent == String(UnicodeScalar(NSF5FunctionKey)!))
        #expect(copy.keyEquivalentModifierMask == [])
        let hidden = try #require(find("Show Hidden Files"))
        #expect(hidden.keyEquivalent == "." && hidden.keyEquivalentModifierMask == [.command, .shift])
        let next = try #require(find("Switch to Next Pane"))
        #expect(next.keyEquivalent.isEmpty, "Tab must not be a menu key equivalent")
        #expect(next.toolTip?.contains("⇥") == true)
    }
}
