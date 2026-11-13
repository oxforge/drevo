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

    @Test func escapeSequencesAreReadPerStream() {
        let b = OutputBacklog(limit: 1000)
        b.append("hello \u{1B}[3", isError: false)
        b.append("warn\u{1B}", isError: true)
        b.append("1mred\u{1B}[0m", isError: false)
        b.append("[1ming\u{1B}[2K", isError: true)
        #expect(b.take().runs == [
            .init(text: "hello ", isError: false),
            .init(text: "warn", isError: true),
            .init(text: "red", isError: false, style: TextStyle(foreground: .palette(1))),
            .init(text: "ing", isError: true, style: TextStyle(bold: true)),
        ])
    }

    @Test func styleLastsAcrossChunksAndTakesAndBelongsToItsStream() {
        let b = OutputBacklog(limit: 1000)
        let green = TextStyle(foreground: .palette(2))
        b.append("\u{1B}[32mgreen ", isError: false)
        b.append("still green", isError: false)
        b.append("not green", isError: true)
        #expect(b.take().runs == [
            .init(text: "green still green", isError: false, style: green),
            .init(text: "not green", isError: true),
        ])
        b.append("after a take\u{1B}[0m plain", isError: false)
        #expect(b.take().runs == [
            .init(text: "after a take", isError: false, style: green),
            .init(text: " plain", isError: false),
        ])
    }

    @Test func theTailKeptPastTheLimitKeepsItsStyles() {
        let b = OutputBacklog(limit: 100)
        let red = TextStyle(foreground: .palette(1))
        b.append("\u{1B}[31m", isError: false)
        for i in 0..<1000 { b.append("line \(i)\n", isError: false) }
        b.append("\u{1B}[1mbold\n", isError: false)
        let batch = b.take()
        #expect(batch.skipped)
        #expect(batch.runs.count == 2)
        #expect(batch.runs.first?.style == red, "set long before the text that was dropped")
        #expect(batch.runs.first?.text.hasSuffix("line 999\n") == true)
        #expect(batch.runs.last == .init(text: "bold\n", isError: false, style: TextStyle(foreground: .palette(1), bold: true)))
        #expect(batch.runs.map(\.text).joined().utf16.count <= 100)
    }

    /// Every line in several colours: many short runs instead of one long one. The limit
    /// holds all the same, and keeping the runs costs about what reading the colours does.
    @Test func aColouredFloodStaysBoundedAndQuick() {
        let line = "\u{1B}[1;32mok\u{1B}[0m the quick \u{1B}[38;5;208mbrown\u{1B}[0m fox\n"
        let shown = "ok the quick brown fox\n"
        let lines = 16_384 / line.utf8.count
        let chunk = String(repeating: line, count: lines)
        let chunks = 10_000_000 / chunk.utf8.count
        // The baseline: the same chunks read into spans, with no backlog keeping them.
        var reader = ANSIStream()
        var visible = 0
        var start = Date()
        for _ in 0..<chunks {
            for span in reader.spans(chunk) { visible += span.text.utf8.count }
        }
        let reading = Date().timeIntervalSince(start)
        #expect(visible == chunks * lines * shown.utf8.count)
        let b = OutputBacklog(limit: 400_000)
        var most = 0
        start = Date()
        for _ in 0..<chunks {
            b.append(chunk, isError: false)
            most = max(most, b.pendingLength)
        }
        let seconds = Date().timeIntervalSince(start)
        // Keeping the runs costs about as much as reading them: 10× (plus 1 s for a tiny
        // baseline) leaves room for a busy machine, not for a pass over all held runs per run.
        #expect(seconds < reading * 10 + 1, "took \(seconds) s; reading the same chunks took \(reading) s")
        #expect(most <= 2 * 400_000 + 16_384)
        let batch = b.take()
        #expect(batch.skipped)
        let text = batch.runs.map(\.text).joined()
        #expect(text.utf16.count <= 400_000 && text.utf16.count > 399_000)
        #expect(text.hasPrefix(shown) && text.hasSuffix(shown))
        #expect(batch.runs.last == .init(text: " fox\n", isError: false))
        #expect(batch.runs.dropLast().last == .init(text: "brown", isError: false, style: TextStyle(foreground: .rgb(255, 135, 0))))
    }

    /// Runs a command that prints 50 MB, hands each chunk of it to `handle`, and returns
    /// the seconds it took.
    func flood(_ handle: @escaping (String, _ isError: Bool) -> Void) -> Double {
        let tmp = TempDir()
        let c = ShellCommand(command: "yes 'the quick brown fox' | head -c 50000000", directory: tmp.url, shell: "/bin/zsh", flags: ["-f"])
        c.onOutput = handle
        let start = Date()
        try! c.start()
        #expect(c.waitUntilExit(timeout: 60))
        return Date().timeIntervalSince(start)
    }

    /// 50 MB from a real command with nothing taking it: the reader keeps up (a per-chunk
    /// walk through the text once made this take 5 s instead of 0.05 s) and holds no more
    /// than the limit allows.
    @Test func aFloodPassesThroughQuicklyAndStaysBounded() {
        nonisolated(unsafe) var received = 0
        let reading = flood { text, _ in received += text.utf8.count }
        #expect(received == 50_000_000)
        let b = OutputBacklog(limit: 400_000)
        nonisolated(unsafe) var most = 0
        let seconds = flood { text, isError in
            b.append(text, isError: isError)
            most = max(most, b.pendingLength)
        }
        // The backlog adds little to reading the output; that walk made it ~100× slower, far
        // past 10× (room for a busy machine) plus 1 s (for a tiny baseline).
        #expect(seconds < reading * 10 + 1, "took \(seconds) s; with the output only counted, \(reading) s")
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
