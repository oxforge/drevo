import Foundation
import Testing
@testable import DrevoCore

@Suite struct MeasureTests {
    let tmp = TempDir()

    @Test func countsBytesAndItems() {
        tmp.file("D/a.txt", String(repeating: "a", count: 10))
        tmp.file("D/sub/b.txt", String(repeating: "b", count: 20))
        let single = tmp.file("c.txt", String(repeating: "c", count: 30))
        let folder = CopyEngine.measure(tmp.url.appendingPathComponent("D"))
        #expect(folder.bytes == 30)
        #expect(folder.items == 4, "D, a.txt, sub, b.txt")
        #expect(CopyEngine.measure(single).bytes == 30)
    }

    @Test func stopsAtTheEntryWhereItIsCancelled() {
        for i in 0..<100 { tmp.file("f\(i).txt") }
        var polls = 0
        let partial = CopyEngine.measure(tmp.url) { polls += 1; return polls > 10 }
        #expect(polls == 11, "asked once per entry, and not again after the answer was yes")
        #expect(partial.items == 11, "the folder and the ten entries before the cancel")
    }

    @Test func aCancelledTokenStopsBeforeTheFirstEntry() {
        for i in 0..<20 { tmp.file("f\(i).txt") }
        let token = CancellationToken()
        #expect(!token.isCancelled)
        token.cancel()
        #expect(token.isCancelled)
        let result = CopyEngine.measure(tmp.url, isCancelled: { token.isCancelled })
        #expect(result.items == 1)
        #expect(result.bytes == 0)
    }

    /// Stop during the size count at the start of a copy ends the transfer without copying.
    @Test func cancellingATransferWhileItMeasuresCopiesNothing() {
        for i in 0..<50 { tmp.file("src/D/f\(i).txt") }
        let dest = tmp.dir("dest")
        let t = Transfer(kind: .copy, sources: [tmp.url.appendingPathComponent("src/D")], destination: dest)
        t.cancel()
        let r = t.run()
        #expect(r.cancelled)
        #expect(r.outputs.isEmpty)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dest.path)) == [])
    }
}
