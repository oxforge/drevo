import AppKit
import Combine
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

    @Test func shellStatusFollowsTheSetupLoading() {
        let env = testEnvironment(trash: fx.url.appendingPathComponent(".T"))
        let model = SettingsModel(env: env)
        var changes = 0
        let watching = model.objectWillChange.sink { changes += 1 }
        defer { watching.cancel() }
        #expect(model.shellSetupStatus == "Loads the first time you use the command line.")
        env.shellSetup.reload()
        #expect(changes == 1, "the Shell tab is told that loading started")
        #expect(model.shellSetupStatus == "Loading…")
        let end = Date().addingTimeInterval(15)
        while env.shellSetup.isLoading, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        #expect(changes == 2, "…and that it ended, so “Loading…” doesn't stay")
        #expect(model.shellSetupStatus.hasPrefix("Loaded in"), "\(model.shellSetupStatus)")
    }

    @Test func returnRenamesRebindsKeys() {
        let wc = makeWindow([fx.url, fx.url])
        wc.env.preferences.returnRenames = true
        #expect(wc.env.keyMap.command(for: .named(.return)) == .rename)
        wc.env.preferences.returnRenames = false
        #expect(wc.env.keyMap.command(for: .named(.return)) == .open)
    }
}

@Test func folderViewerRefusalIsExplained() {
    // What NSWorkspace returns on macOS 26 for public.folder (reproduced on this machine).
    let refused = NSError(domain: NSCocoaErrorDomain, code: 256,
                          userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -50)])
    let p = FolderViewerProblem(refused)
    #expect(p.refusedByMacOS)
    #expect(p.title == "macOS keeps folders in Finder.")
    #expect(p.detail.contains("Open folders in fman"))
    let other = FolderViewerProblem(NSError(domain: NSOSStatusErrorDomain, code: -10814))
    #expect(!other.refusedByMacOS)
    #expect(other.detail.contains("-10814"), "other failures show their code instead of a vague message")
}
