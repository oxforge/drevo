import Foundation
import Testing
@testable import DrevoCore

@Suite struct OutputBacklogTests {
    @Test func keepsOrderAndMergesNeighboursOfOneStream() {
        let b = OutputBacklog(limit: 1000)
        b.append("one\n", isError: false)
        b.append("two\n", isError: false)
        b.append("oops\n", isError: true)
        b.append("three\n", isError: false)
        let batch = b.take()
        #expect(batch.runs == [
            .init(text: "one\ntwo\n", isError: false),
            .init(text: "oops\n", isError: true),
            .init(text: "three\n", isError: false),
        ])
        #expect(!batch.skipped)
        #expect(b.take().isEmpty, "taking empties it")
    }

    @Test func saysWhenItBecomesNonEmpty() {
        let b = OutputBacklog(limit: 1000)
        #expect(b.append("a", isError: false), "first text: the console has to be told")
        #expect(!b.append("b", isError: false), "already told")
        #expect(!b.append("c", isError: true))
        _ = b.take()
        #expect(b.append("d", isError: false), "empty again after a take")
        _ = b.take()
        #expect(!b.append("\u{1B}[0m", isError: false), "nothing visible arrived")
    }

    @Test func keepsOnlyTheTailPastTheLimit() {
        let b = OutputBacklog(limit: 100)
        for i in 0..<1000 { b.append("line \(i)\n", isError: false) }
        let batch = b.take()
        let text = batch.runs.map(\.text).joined()
        #expect(batch.skipped)
        #expect(text.utf16.count <= 100)
        #expect(text.utf16.count > 80, "the tail is not cut shorter than a line or so below the limit")
        #expect(text.hasSuffix("line 998\nline 999\n"))
        #expect(text.hasPrefix("line "), "resumes at the start of a line")
        let next = b.take()
        #expect(!next.skipped && next.isEmpty, "the skip is reported once")
    }

    @Test func memoryStaysBoundedWhileNothingTakesIt() {
        let b = OutputBacklog(limit: 1000)
        let chunk = String(repeating: "x", count: 300)
        for _ in 0..<10_000 {
            b.append(chunk, isError: false)
            #expect(b.pendingLength <= 2 * 1000 + 300)
        }
        let batch = b.take()
        #expect(batch.skipped)
        #expect(batch.runs.map(\.text).joined().utf16.count == 1000, "no line break to resume at: an exact cut")
    }

    @Test func skippingDropsWholeOlderRunsOfTheOtherStream() {
        let b = OutputBacklog(limit: 50)
        b.append(String(repeating: "e", count: 40), isError: true)
        b.append(String(repeating: "o", count: 40), isError: false)
        b.append(String(repeating: "E", count: 40), isError: true)
        let batch = b.take()
        #expect(batch.skipped)
        #expect(batch.runs == [
            .init(text: String(repeating: "o", count: 10), isError: false),
            .init(text: String(repeating: "E", count: 40), isError: true),
        ])
    }

    @Test func cutsBetweenCharactersNotInsideOne() {
        let b = OutputBacklog(limit: 5)
        b.append("ab😀😀😀", isError: false) // 2 + 3×2 UTF-16 units; the cut at 3 falls inside an emoji
        let text = b.take().runs.map(\.text).joined()
        #expect(text == "😀😀")
    }

    @Test func escapeSequencesAreStrippedPerStream() {
        let b = OutputBacklog(limit: 1000)
        b.append("hello \u{1B}[3", isError: false)
        b.append("warn\u{1B}", isError: true)
        b.append("1mred\u{1B}[0m", isError: false)
        b.append("[1ming", isError: true)
        #expect(b.take().runs == [
            .init(text: "hello ", isError: false),
            .init(text: "warn", isError: true),
            .init(text: "red", isError: false),
            .init(text: "ing", isError: true),
        ])
    }

    /// 50 MB from a real command with nothing taking it: the reader keeps up (a per-chunk
    /// walk through the text once made this take 5 s instead of 0.05 s) and holds no more
    /// than the limit allows.
    @Test func aFloodPassesThroughQuicklyAndStaysBounded() {
        let tmp = TempDir()
        let c = ShellCommand(command: "yes 'the quick brown fox' | head -c 50000000", directory: tmp.url, shell: "/bin/zsh", flags: ["-f"])
        let b = OutputBacklog(limit: 400_000)
        nonisolated(unsafe) var most = 0
        c.onOutput = { text, isError in
            b.append(text, isError: isError)
            most = max(most, b.pendingLength)
        }
        let start = Date()
        try! c.start()
        #expect(c.waitUntilExit(timeout: 60))
        #expect(Date().timeIntervalSince(start) < 2.5)
        #expect(most <= 2 * 400_000 + 16_384, "at most twice the limit plus one chunk is ever held")
        let batch = b.take()
        #expect(batch.skipped)
        let text = batch.runs.map(\.text).joined()
        #expect(text.utf16.count == 400_000)
        #expect(text.hasSuffix("the quick brown fox\n"))
    }

    @Test func appendsFromSeveralThreadsLoseNothing() {
        let b = OutputBacklog(limit: 1_000_000)
        DispatchQueue.concurrentPerform(iterations: 8) { t in
            for _ in 0..<1000 { b.append("x", isError: t % 2 == 0) }
        }
        #expect(b.take().runs.reduce(0) { $0 + $1.text.count } == 8000)
    }
}
