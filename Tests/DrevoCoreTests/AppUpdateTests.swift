import Foundation
import Testing
@testable import DrevoCore

@Suite struct AppUpdateTests {
    @Test func versionsCompareByNumber() throws {
        let v = { (s: String) in try #require(AppVersion(s)) }
        #expect(try v("0.3.1") < v("0.3.2"))
        #expect(try v("0.9") < v("0.10"), "numbers, not text")
        #expect(try v("v0.4.0") > v("0.3.9"))
        #expect(try v("1.0") == v("1.0.0"))
        #expect(try v("0.4.0-beta1") < v("0.4.0"), "a pre-release comes before its release")
        #expect(try v("0.4.0-beta2") < v("0.4.0-beta10"))
        #expect(try v("v0.4.0-rc1").description == "0.4.0-rc1")
    }

    @Test func textThatIsNoVersionIsRefused() {
        for text in ["", "latest", "1.x", "1..2", "-1.0", "v"] {
            #expect(AppVersion(text) == nil, "\(text)")
        }
    }

    @Test func releaseIsReadFromGitHubsAnswer() throws {
        let json = """
        {"tag_name": "v0.4.0", "html_url": "https://github.com/oxforge/drevo/releases/tag/v0.4.0",
         "body": "New things.", "prerelease": false,
         "assets": [{"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"},
                    {"name": "Drevo-0.4.0.dmg", "browser_download_url": "https://example.com/Drevo-0.4.0.dmg"}]}
        """
        let release = try AppRelease.parse(Data(json.utf8))
        #expect(release.version == AppVersion("0.4.0"))
        #expect(release.notes == "New things.")
        #expect(release.page.absoluteString == "https://github.com/oxforge/drevo/releases/tag/v0.4.0")
        #expect(release.diskImage?.absoluteString == "https://example.com/Drevo-0.4.0.dmg")
    }

    @Test func releaseWithoutADiskImageOrWithAnInsecureOneHasNone() throws {
        let none = #"{"tag_name": "v0.4.0", "html_url": "https://example.com/r", "assets": []}"#
        #expect(try AppRelease.parse(Data(none.utf8)).diskImage == nil)
        let http = #"{"tag_name": "v0.4.0", "html_url": "https://example.com/r", "assets": [{"name": "D.dmg", "browser_download_url": "http://example.com/D.dmg"}]}"#
        #expect(try AppRelease.parse(Data(http.utf8)).diskImage == nil)
    }

    @Test func otherAnswersAreErrors() {
        #expect(throws: AppRelease.Unreadable.self) { try AppRelease.parse(Data(#"{"message": "Not Found"}"#.utf8)) }
        #expect(throws: AppRelease.Unreadable.self) { try AppRelease.parse(Data(#"{"tag_name": "nightly", "html_url": "https://example.com"}"#.utf8)) }
        #expect(throws: AppRelease.Unreadable.self) { try AppRelease.parse(Data("<html>".utf8)) }
    }
}

@Suite struct AppInstallTests {
    let tmp = TempDir()

    func bundle(_ path: String, marker: String) -> URL {
        tmp.file("\(path)/Contents/MacOS/Drevo", marker)
        return tmp.url.appendingPathComponent(path)
    }

    func marker(_ app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/MacOS/Drevo"), encoding: .utf8)
    }

    func names(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: tmp.url.appendingPathComponent(folder).path)) ?? []).sorted()
    }

    @Test func stageThenSwapReplacesTheAppAndLeavesNothingBehind() throws {
        let installed = bundle("Apps/Drevo.app", marker: "old")
        let new = bundle("Image/Drevo.app", marker: "new")
        let staged = try AppInstall.stage(new, for: installed)
        #expect(marker(installed) == "old", "staging doesn't touch the installed app")
        #expect(staged.deletingLastPathComponent().path == installed.deletingLastPathComponent().path)
        try AppInstall.swap(staged: staged, installed: installed)
        #expect(marker(installed) == "new")
        #expect(names("Apps") == ["Drevo.app"])
        #expect(marker(new) == "new", "the source stays")
    }

    @Test func aFailedSwapPutsTheOldAppBack() throws {
        let installed = bundle("Apps/Drevo.app", marker: "old")
        let missing = tmp.url.appendingPathComponent("Apps/.gone.app")
        #expect(throws: (any Error).self) { try AppInstall.swap(staged: missing, installed: installed) }
        #expect(marker(installed) == "old")
        #expect(names("Apps") == ["Drevo.app"])
    }

    @Test func obstaclesAreNamed() {
        let installed = bundle("Apps/Drevo.app", marker: "old")
        #expect(AppInstall.obstacle(for: installed) == nil)
        #expect(AppInstall.obstacle(for: tmp.url.appendingPathComponent("bin/drevo")) != nil)
        #expect(AppInstall.obstacle(for: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Drevo.app")) != nil)
        try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tmp.url.appendingPathComponent("Apps").path)
        defer { try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.url.appendingPathComponent("Apps").path) }
        #expect(AppInstall.obstacle(for: installed) != nil)
    }
}
