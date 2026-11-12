import AppKit
import SwiftUI
import Testing
@testable import FmanCore
@testable import FmanUI

@MainActor
@Suite(.serialized) struct IntegrationTests {
    let fx = Fixture()

    init() {
        fx.dir("Folder/Inner")
        fx.file("Folder/a.txt")
        fx.file("Folder/b.txt")
    }

    func delegate() -> AppDelegate {
        let d = AppDelegate(options: LaunchOptions(arguments: ["fman", "--ephemeral"]))
        d.useEnvironmentForTests(testEnvironment(trash: fx.url.appendingPathComponent(".T")))
        return d
    }

    @Test func openingAFolderShowsItInTheActivePane() {
        let d = delegate()
        let wc = d.openWindow(directories: [fx.url, fx.url], viewModes: [.list, .list])
        d.application(NSApp, open: [fx.url.appendingPathComponent("Folder/Inner")])
        #expect(wc.paneGroup.activePane.currentDirectory.lastPathComponent == "Inner")
        wc.close()
    }

    @Test func openingFilesRevealsThem() {
        let d = delegate()
        let wc = d.openWindow(directories: [fx.url, fx.url], viewModes: [.list, .list])
        d.application(NSApp, open: [fx.url.appendingPathComponent("Folder/a.txt"), fx.url.appendingPathComponent("Folder/b.txt")])
        let pane = wc.paneGroup.activePane
        #expect(pane.currentDirectory.lastPathComponent == "Folder")
        #expect(pane.selectedItems.map(\.name) == ["a.txt", "b.txt"])
        wc.close()
    }

    @Test func revealAppleEventCarriesFileURLs() {
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(fileURL: fx.url.appendingPathComponent("Folder/a.txt")), at: 1)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAEMiscStandards), eventID: AEEventID(kAEMakeObjectsVisible),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(list, forKeyword: keyDirectObject)
        #expect(AppDelegate.fileURLs(in: event).map(\.lastPathComponent) == ["a.txt"])
    }

    @Test func servicesProviderOpensFiles() {
        let d = delegate()
        let wc = d.openWindow(directories: [fx.url, fx.url], viewModes: [.list, .list])
        let pb = NSPasteboard(name: NSPasteboard.Name("fman.service.\(UUID().uuidString)"))
        pb.clearContents()
        pb.writeObjects([fx.url.appendingPathComponent("Folder/Inner") as NSURL])
        d.openInFman(pb, userData: nil, error: AutoreleasingUnsafeMutablePointer<NSString?>(UnsafeMutablePointer<NSString?>.allocate(capacity: 1)))
        #expect(wc.paneGroup.activePane.currentDirectory.lastPathComponent == "Inner")
        wc.close()
    }

    @Test func settingsBindingsWriteThrough() {
        let env = testEnvironment(trash: fx.url.appendingPathComponent(".T"))
        let model = SettingsModel(env: env)
        let b = model.binding(\.showHidden)
        b.wrappedValue = true
        #expect(env.preferences.showHidden)
        model.binding(\.returnRenames).wrappedValue = true
        #expect(env.preferences.returnRenames)
        let view = NSHostingView(rootView: SettingsView(model: model))
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width > 400)
    }

    @Test func returnRenamesRebindsKeys() {
        let wc = makeWindow([fx.url, fx.url])
        wc.env.preferences.returnRenames = true
        #expect(wc.env.keyMap.command(for: .named(.return)) == .rename)
        wc.env.preferences.returnRenames = false
        #expect(wc.env.keyMap.command(for: .named(.return)) == .open)
    }
}
