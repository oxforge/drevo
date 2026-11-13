import AppKit
import Testing
@testable import DrevoCore
@testable import DrevoUI

@MainActor
@Suite struct UpdaterTests {
    let fx = Fixture()
    let prompts = ScriptedPrompts()
    let installed: URL

    /// What the scripted services saw.
    final class Seen {
        var opened: [URL] = []
        var quits = 0
        var relaunched: [URL] = []
        var fetched: [URL] = []
    }
    let seen = Seen()

    init() {
        fx.file("Apps/Drevo.app/Contents/MacOS/Drevo", "old")
        fx.file("Image/Drevo.app/Contents/MacOS/Drevo", "new")
        installed = fx.url.appendingPathComponent("Apps/Drevo.app")
    }

    func release(_ version: String, image: Bool = true) -> AppRelease {
        AppRelease(version: AppVersion(version)!, notes: "## New\n- **Things**",
                   page: URL(string: "https://example.com/release")!,
                   diskImage: image ? URL(string: "https://example.com/Drevo.dmg")! : nil)
    }

    /// An updater at version 0.3.1 whose "download" stages the fixture's new app, or fails.
    func updater(latest: Result<AppRelease, Error>, fetchError: Error? = nil, installed: URL? = nil) -> Updater {
        let seen = seen
        let newApp = fx.url.appendingPathComponent("Image/Drevo.app")
        return Updater(services: Updater.Services(
            currentVersion: AppVersion("0.3.1"),
            installedApp: installed ?? self.installed,
            latestRelease: { $0(latest) },
            fetch: { image, installed, _, progress, completion in
                seen.fetched.append(image)
                progress(0.5)
                completion(Result { if let fetchError { throw fetchError }; return try AppInstall.stage(newApp, for: installed) })
            },
            openPage: { seen.opened.append($0) },
            quit: { seen.quits += 1 },
            relaunch: { seen.relaunched.append($0) },
            showsProgressPanel: false), prompts: prompts)
    }

    var installedMarker: String? {
        try? String(contentsOf: installed.appendingPathComponent("Contents/MacOS/Drevo"), encoding: .utf8)
    }

    var appsFolder: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)) ?? []).sorted()
    }

    @Test func theSameOrAnOlderReleaseMeansUpToDate() {
        for version in ["0.3.1", "0.3.0"] {
            updater(latest: .success(release(version))).check()
        }
        #expect(prompts.infos.count == 2)
        #expect(prompts.infos.first?.contains("0.3.1 is the latest version") == true)
        #expect(prompts.offeredUpdates.isEmpty)
        #expect(seen.fetched.isEmpty)
    }

    @Test func aFailedCheckSaysWhy() {
        updater(latest: .failure(UpdateFetch.Failure("No network."))).check()
        #expect(prompts.errors.first?.contains("No network.") == true)
    }

    @Test func laterLeavesEverythingAlone() {
        prompts.installAnswer = false
        let u = updater(latest: .success(release("0.4.0")))
        u.check()
        #expect(prompts.offeredUpdates == ["0.4.0"])
        #expect(seen.fetched.isEmpty)
        #expect(seen.quits == 0)
        u.finishOnQuit()
        #expect(installedMarker == "old")
    }

    @Test func installDownloadsQuitsAndSwapsOnlyOnceQuittingIsCertain() {
        let u = updater(latest: .success(release("0.4.0")))
        u.check()
        #expect(seen.fetched.count == 1)
        #expect(seen.quits == 1)
        #expect(installedMarker == "old", "nothing is replaced while the app may still keep running")
        #expect(seen.relaunched.isEmpty)
        u.finishOnQuit()
        #expect(installedMarker == "new")
        #expect(seen.relaunched == [installed])
        #expect(appsFolder == ["Drevo.app"])
        u.finishOnQuit()
        #expect(seen.relaunched.count == 1, "a second call has nothing to do")
    }

    @Test func checkingAgainAfterAQuitThatWasCancelledReusesTheDownload() {
        let u = updater(latest: .success(release("0.4.0")))
        u.check()
        u.check()
        #expect(seen.fetched.count == 1)
        #expect(seen.quits == 2)
    }

    @Test func aFailedDownloadOffersTheReleasePage() {
        let u = updater(latest: .success(release("0.4.0")), fetchError: UpdateFetch.Failure("The signature doesn’t match."))
        u.check()
        #expect(prompts.confirmations == ["Drevo 0.4.0 can’t be installed automatically."])
        #expect(seen.opened.map(\.absoluteString) == ["https://example.com/release"])
        #expect(seen.quits == 0)
        #expect(u.staged == nil)
        #expect(appsFolder == ["Drevo.app"])
    }

    @Test func noDiskImageOrNoAppBundleOffersTheReleasePageWithoutDownloading() {
        updater(latest: .success(release("0.4.0", image: false))).check()
        updater(latest: .success(release("0.4.0")), installed: fx.url.appendingPathComponent("bin/drevo")).check()
        #expect(prompts.confirmations.count == 2)
        #expect(seen.fetched.isEmpty)
        #expect(seen.opened.count == 2)
    }

    @Test func releaseNotesKeepTheirWordsAndDropTheMarkup() {
        let text = ReleaseNotes.text("## New: keys\n- **Change a key** by pressing `it`.")
        #expect(text.string == "New: keys\n- Change a key by pressing it.\n")
        let bold = text.attribute(.font, at: 12, effectiveRange: nil) as? NSFont
        #expect(bold?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test func theAppMenuHasTheItemUnderAbout() throws {
        _ = NSApplication.shared // the menu registers its Services submenu with NSApp
        let app = try #require(MainMenu.build(keyMap: KeyMap()).items.first?.submenu)
        #expect(app.items.prefix(2).map(\.title) == ["About Drevo", "Check for Updates…"])
        #expect(app.items[1].action == #selector(AppDelegate.checkForUpdates(_:)))
    }
}
