import Testing
@testable import DrevoUI

@Test func parsesSnapshotAndOpenPaths() {
    let o = LaunchOptions(arguments: ["drevo", "--snapshot", "/tmp/x.png", "--dark", "--open", "/a", "--open", "/b", "-psn_0_123"])
    #expect(o.snapshotPath == "/tmp/x.png")
    #expect(o.appearance == "dark")
    #expect(o.openPaths == ["/a", "/b"])
    #expect(o.ephemeralSettings)
}

