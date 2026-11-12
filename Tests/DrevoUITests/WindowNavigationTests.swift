import AppKit
import Testing
@testable import DrevoCore
@testable import DrevoUI

@MainActor
@Suite(.serialized) struct WindowNavigationTests {
    let fx = Fixture()

    init() {
        fx.dir("alpha/inner")
        fx.dir("beta")
        fx.file("alpha/a.txt")
        fx.file("note.txt")
        fx.file(".secret")
    }

    func names(_ pane: PaneViewController) -> [String] { pane.browser.visibleItems.map(\.name) }

    @Test func showsTwoPanesWithListings() {
        let wc = makeWindow([fx.url, fx.url.appendingPathComponent("beta")])
        #expect(wc.paneGroup.panes.count == 2)
        #expect(names(wc.paneGroup.panes[0]) == ["alpha", "beta", "note.txt"])
        #expect(wc.paneGroup.activePane === wc.paneGroup.panes[0])
        #expect(wc.window?.title == fx.url.lastPathComponent)
    }

    @Test func tabSwitchesPanesAndTargetFollows() {
        let wc = makeWindow([fx.url, fx.url])
        let w = wc.window!
        press(key(KeyCode.tab, "\t", window: w), in: w)
        #expect(wc.paneGroup.activeIndex == 1)
        #expect(wc.paneGroup.targetPane === wc.paneGroup.panes[0])
        #expect(wc.paneGroup.panes[1].browser.hasFocus)
        press(key(KeyCode.tab, "\u{19}", .shift, window: w), in: w)
        #expect(wc.paneGroup.activeIndex == 0)
    }

    @Test func rightEntersLeftReturnsAndSelectsOrigin() {
        let wc = makeWindow([fx.url, fx.url])
        let w = wc.window!
        let pane = wc.paneGroup.activePane
        pane.browser.select([fx.url.appendingPathComponent("alpha")])
        press(key(KeyCode.right, String(UnicodeScalar(NSRightArrowFunctionKey)!), .function, window: w), in: w)
        #expect(pane.currentDirectory.lastPathComponent == "alpha")
        #expect(names(pane) == ["inner", "a.txt"])
        press(key(KeyCode.left, String(UnicodeScalar(NSLeftArrowFunctionKey)!), .function, window: w), in: w)
        #expect(pane.currentDirectory.standardizedFileURL.path == fx.url.standardizedFileURL.path)
        #expect(pane.selectedItems.map(\.name) == ["alpha"], "coming back up selects the folder you left")
    }

    @Test func returnOpensFolderAndFiles() {
        let opener = RecordingOpener()
        let wc = makeWindow([fx.url, fx.url], env: testEnvironment(trash: fx.url.appendingPathComponent(".T"), opener: opener))
        let w = wc.window!
        let pane = wc.paneGroup.activePane
        pane.browser.select([fx.url.appendingPathComponent("beta")])
        press(key(KeyCode.returnKey, "\r", window: w), in: w)
        #expect(pane.currentDirectory.lastPathComponent == "beta")
        wc.perform(.back)
        #expect(pane.currentDirectory.lastPathComponent == fx.url.lastPathComponent)
        wc.perform(.forward)
        #expect(pane.currentDirectory.lastPathComponent == "beta")
        wc.perform(.enclosingFolder)
        pane.browser.select([fx.url.appendingPathComponent("note.txt")])
        press(key(KeyCode.returnKey, "\r", window: w), in: w)
        #expect(opener.opened.last?.map(\.lastPathComponent) == ["note.txt"])
    }

    @Test func hiddenFilesToggleReloadsAllPanes() {
        let wc = makeWindow([fx.url, fx.url])
        #expect(!names(wc.paneGroup.panes[1]).contains(".secret"))
        wc.perform(.toggleHidden)
        #expect(names(wc.paneGroup.panes[0]).contains(".secret"))
        #expect(names(wc.paneGroup.panes[1]).contains(".secret"))
    }

    @Test func menuShortcutForHiddenFilesFires() {
        let wc = makeWindow([fx.url, fx.url])
        NSApp.mainMenu = MainMenu.build(keyMap: wc.env.keyMap)
        let w = wc.window!
        // ⇧⌘. as the keyboard delivers it: characters are the shifted ">".
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                 windowNumber: w.windowNumber, context: nil, characters: ">",
                                 charactersIgnoringModifiers: ">", isARepeat: false, keyCode: KeyCode.period)!
        #expect(KeyCombo.candidates(for: e).contains(try! KeyCombo(parsing: "shift+cmd+.")))
        #expect(wc.env.keyMap.command(for: e) == .toggleHidden)
    }

    @Test func bangMapsToRunCommand() {
        let wc = makeWindow([fx.url, fx.url])
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
                                 windowNumber: wc.window!.windowNumber, context: nil, characters: "!",
                                 charactersIgnoringModifiers: "!", isARepeat: false, keyCode: KeyCode.one)!
        #expect(wc.env.keyMap.command(for: e) == .runCommand)
    }

    @Test func viewModeSwitchKeepsFolderAndSelection() {
        let wc = makeWindow([fx.url, fx.url])
        let pane = wc.paneGroup.activePane
        pane.browser.select([fx.url.appendingPathComponent("beta")])
        wc.perform(.columnsView)
        #expect(pane.viewMode == .columns)
        #expect(pane.currentDirectory.standardizedFileURL.path == fx.url.standardizedFileURL.path)
        #expect(pane.selectedItems.map(\.name) == ["beta"])
        wc.perform(.listView)
        #expect(pane.selectedItems.map(\.name) == ["beta"])
    }

    @Test func swapAndOpenInOtherPane() {
        let wc = makeWindow([fx.url, fx.url.appendingPathComponent("beta")])
        let (a, b) = (wc.paneGroup.panes[0], wc.paneGroup.panes[1])
        wc.perform(.swapPanes)
        #expect(a.currentDirectory.lastPathComponent == "beta")
        #expect(b.currentDirectory.standardizedFileURL.path == fx.url.standardizedFileURL.path)
        wc.perform(.swapPanes)
        a.browser.select([fx.url.appendingPathComponent("alpha")])
        wc.perform(.openInOtherPane)
        #expect(b.currentDirectory.lastPathComponent == "alpha")
        #expect(wc.paneGroup.activePane === a)
    }

    @Test func threePanesTargetIsPreviouslyActive() {
        let wc = makeWindow([fx.url, fx.url, fx.url], modes: [.list, .list, .list])
        wc.paneGroup.activate(index: 2)
        #expect(wc.paneGroup.targetPane === wc.paneGroup.panes[0])
        #expect(wc.paneGroup.panes[0].header.badgeText == "TARGET")
        wc.paneGroup.activate(index: 1)
        #expect(wc.paneGroup.targetPane === wc.paneGroup.panes[2])
    }
}
