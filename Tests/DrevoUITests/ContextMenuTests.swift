import AppKit
import Testing
@testable import DrevoCore
@testable import DrevoUI

@MainActor
@Suite(.serialized) struct ContextMenuTests {
    let fx = Fixture()
    let opener = RecordingOpener()

    init() {
        fx.file("doc.txt", "hi")
        fx.dir("Folder")
        fx.dir("App.app/Contents")
        fx.file("App.app/Contents/Info.plist", "<plist/>")
    }

    func window() -> MainWindowController {
        makeWindow([fx.url, fx.url], env: testEnvironment(trash: fx.url.appendingPathComponent(".T"), opener: opener))
    }

    func titles(_ menu: NSMenu?) -> [String] { menu?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? [] }

    @Test func itemMenuHasOpenWithAndOperations() throws {
        let wc = window()
        let pane = wc.paneGroup.activePane
        pane.browser.select([fx.url.appendingPathComponent("doc.txt")])
        let menu = pane.browser(pane.browser, menuFor: pane.selectedItems)
        let t = titles(menu)
        for expected in ["Open", "Open With", "Quick Look", "Copy", "Rename", "Copy to Other Pane", "Copy Path", "Get Info", "Move to Trash"] {
            #expect(t.contains(expected), "missing \(expected)")
        }
        let openWith = try #require(menu?.items.first { $0.title == "Open With" }?.submenu)
        #expect(openWith.items.last?.title == "Other…")
    }

    @Test func backgroundMenuOffersCreationAndTerminal() {
        let wc = window()
        let pane = wc.paneGroup.activePane
        let t = titles(pane.browser(pane.browser, menuFor: []))
        #expect(t.prefix(3) == ["New Folder", "New File", "Paste"])
        #expect(t.contains("Open in Terminal"))
        #expect(t.contains("Run Shell Command…"))
    }

    @Test func packageMenuShowsContentsAndEntersIt() {
        let wc = window()
        let pane = wc.paneGroup.activePane
        pane.browser.select([fx.url.appendingPathComponent("App.app")])
        #expect(titles(pane.browser(pane.browser, menuFor: pane.selectedItems)).contains("Show Package Contents"))
        wc.perform(.showPackageContents)
        #expect(pane.currentDirectory.lastPathComponent == "App.app")
        #expect(pane.browser.visibleItems.map(\.name) == ["Contents"])
    }

    @Test func f4OpensInEditor() {
        let wc = window()
        let pane = wc.paneGroup.activePane
        pane.browser.select([fx.url.appendingPathComponent("doc.txt")])
        wc.perform(.edit)
        #expect(opener.opened.last?.map(\.lastPathComponent) == ["doc.txt"])
    }

    @Test func getInfoOpensPanel() {
        let wc = window()
        let pane = wc.paneGroup.activePane
        pane.browser.select([fx.url.appendingPathComponent("doc.txt")])
        let before = NSApp.windows.filter { $0.title.hasSuffix("Info") && $0.isVisible }.count
        wc.perform(.getInfo)
        let panels = NSApp.windows.filter { $0.title == "doc.txt Info" && $0.isVisible }
        #expect(panels.count == 1)
        #expect(NSApp.windows.filter { $0.title.hasSuffix("Info") && $0.isVisible }.count == before + 1)
        panels.forEach { $0.close() }
    }

    @Test func permissionString() {
        #expect(InfoPanel.permissionString(0o755) == "rwxr-xr-x")
        #expect(InfoPanel.permissionString(0o640) == "rw-r-----")
    }
}

@MainActor
@Suite(.serialized) struct AliasTests {
    @Test func openingAnAliasToAFolderEntersTheTarget() throws {
        let fx = Fixture()
        let target = fx.dir("Real/Inside")
        let data = try target.deletingLastPathComponent().bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(data, to: fx.url.appendingPathComponent("Real alias"))
        let wc = makeWindow([fx.url, fx.url])
        let pane = wc.paneGroup.activePane
        pane.browser.select([fx.url.appendingPathComponent("Real alias")])
        wc.perform(.open)
        #expect(pane.currentDirectory.lastPathComponent == "Real")
    }
}
