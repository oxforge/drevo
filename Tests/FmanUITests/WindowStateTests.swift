import AppKit
import Testing
@testable import FmanUI

@MainActor
@Suite(.serialized) struct WindowStateTests {
    let fx = Fixture()

    @Test func roundTripsAndValidates() throws {
        let s = WindowState(panes: [.init(path: fx.url.path, viewMode: "list"), .init(path: "/nonexistent/xyz", viewMode: "columns")], activeIndex: 5)
        let back = try #require(WindowState.decode(s.encoded()))
        #expect(back == s)
        let v = back.validated()
        #expect(v.panes[1].path == FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(v.activeIndex == 1)
        #expect(v.viewModes == [.list, .columns])
    }

    @Test func windowSavesItsPanes() {
        fx.dir("sub")
        let wc = makeWindow([fx.url, fx.url], modes: [.list, .columns])
        wc.paneGroup.activePane.navigate(to: fx.url.appendingPathComponent("sub"))
        let saved = WindowState.decode(wc.env.preferences.savedWindowState)
        #expect(saved?.panes.first?.path.hasSuffix("/sub") == true)
        #expect(saved?.panes.map(\.viewMode) == ["list", "columns"])
    }

    @Test func garbageIsIgnored() {
        #expect(WindowState.decode(Data("nope".utf8)) == nil)
        #expect(WindowState.decode(nil) == nil)
    }
}
