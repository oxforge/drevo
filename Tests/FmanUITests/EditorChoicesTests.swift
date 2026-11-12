import Foundation
import Testing
@testable import FmanUI

/// The apps offered for F4 in Settings.
@Suite struct EditorChoicesTests {
    let fx = Fixture()

    private func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }

    @Test func offersAnyAppInTheApplicationsFolders() {
        let apps = fx.dir("Applications")
        let codium = fx.dir("Applications/VSCodium.app")
        let nested = fx.dir("Applications/Tools/Hex.app")

        let list = EditorChoices.list(candidates: [codium, nested], chosen: nil, appFolders: [apps])

        #expect(names(list) == ["Hex.app", "VSCodium.app"])
    }

    @Test func leavesOutCopiesOutsideTheApplicationsFolders() {
        let apps = fx.dir("Applications")
        let real = fx.dir("Applications/Zed.app")
        let cached = fx.dir("Caches/browser/Chromium.app")

        let list = EditorChoices.list(candidates: [cached, real], chosen: nil, appFolders: [apps])

        #expect(names(list) == ["Zed.app"])
    }

    @Test func keepsTheChosenAppWhereverItIs() {
        let apps = fx.dir("Applications")
        let real = fx.dir("Applications/Zed.app")
        let elsewhere = fx.dir("Downloads/Kate.app")

        let list = EditorChoices.list(candidates: [real], chosen: elsewhere.path, appFolders: [apps])

        #expect(names(list) == ["Kate.app", "Zed.app"])
    }

    @Test func dropsAChosenAppThatIsGone() {
        let apps = fx.dir("Applications")
        let real = fx.dir("Applications/Zed.app")
        let gone = fx.url.appendingPathComponent("Applications/Removed.app")

        let list = EditorChoices.list(candidates: [real], chosen: gone.path, appFolders: [apps])

        #expect(names(list) == ["Zed.app"])
    }

    @Test func listsEachAppOnceSortedByNameIgnoringCase() {
        let apps = fx.dir("Applications")
        let b = fx.dir("Applications/bbedit.app")
        let a = fx.dir("Applications/Atom.app")
        let z = fx.dir("Applications/Zed.app")

        let list = EditorChoices.list(candidates: [z, b, a, z], chosen: b.path, appFolders: [apps])

        #expect(names(list) == ["Atom.app", "bbedit.app", "Zed.app"])
    }
}
