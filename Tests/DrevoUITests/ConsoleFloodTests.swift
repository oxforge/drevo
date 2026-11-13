import AppKit
import Testing
@testable import DrevoCore
@testable import DrevoUI

/// Records when a repeating main-run-loop timer fires: the gaps show how long the main
/// thread was unavailable to everything else (events, ⌘., redraws).
@MainActor
final class Heartbeat {
    private var timer: Timer?
    private(set) var beats: [Date] = [Date()]

    init(every interval: TimeInterval = 0.05) {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beats.append(Date()) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops and returns the longest time between two beats.
    func stop() -> TimeInterval {
        timer?.invalidate()
        beats.append(Date())
        return zip(beats, beats.dropFirst()).map { $1.timeIntervalSince($0) }.max() ?? 0
    }
}

/// The longest the main run loop goes without firing a 50 Hz timer while `command` runs
/// in `wc`'s command line, and the same for a command that prints nothing.
///
/// The longest gap also holds work every command causes, whatever it prints: the console
/// opening (the window lays out again) and, at the end, the panes reloading and everything
/// redrawing. That is ~0.1 s on a fast Mac, where 50 MB of output costs the console a few
/// ms, and most likely what the CI runner measured as 1.1–1.4 s gaps against a 1 s limit.
/// So the console is opened first, and the quiet command is the baseline to compare with.
@MainActor
func mainRunLoopGaps(running command: String, in wc: MainWindowController) -> (command: TimeInterval, quiet: TimeInterval) {
    func longestGap(_ command: String) -> TimeInterval {
        wc.commandBar.field.stringValue = command
        wc.commandBar.submit(inTerminal: false)
        let heartbeat = Heartbeat(every: 0.02)
        let end = Date().addingTimeInterval(60)
        while wc.shell.isRunning, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        #expect(!wc.shell.isRunning, "“\(command)” ended within a minute")
        return heartbeat.stop()
    }
    _ = longestGap("true") // opens the console
    let quiet = longestGap("true")
    return (longestGap(command), quiet)
}

/// The console under commands that print faster than a text view can render (review C1),
/// and what it shows of their output.
@MainActor
@Suite(.serialized) struct ConsoleFloodTests {
    let fx = Fixture()
    let line = "the quick brown fox"

    func window() -> MainWindowController {
        let wc = makeWindow([fx.url, fx.url], env: testEnvironment(trash: fx.url.appendingPathComponent(".T")))
        wc.shell.shellOverride = ("/bin/zsh", ["-f"]) // never run the user's rc files in tests
        return wc
    }

    func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    func run(_ command: String, in wc: MainWindowController) {
        wc.commandBar.field.stringValue = command
        wc.commandBar.submit(inTerminal: false)
    }

    /// The console's text view, to see where it is scrolled.
    func transcriptView(_ wc: MainWindowController) -> NSTextView {
        func find(_ v: NSView) -> NSTextView? { (v as? NSTextView) ?? v.subviews.lazy.compactMap(find).first }
        return find(wc.workspace.console.view)!
    }

    /// The transcript is longer than the view, and its last line is in view.
    func showsItsEnd(_ view: NSTextView) -> Bool {
        view.window?.layoutIfNeeded()
        return view.bounds.height > view.visibleRect.height && view.visibleRect.maxY >= view.bounds.maxY - 2
    }

    // MARK: Fast output

    // Before the fix this command held the main thread for 8 s without a timer firing once.
    // Now it is over in a fraction of a second (a couple of console updates), so there is
    // no rate to measure here; the endless command below measures one. Other suites share
    // the main thread through nested run loops, hence the slack in the limits.
    @Test func fastOutputLeavesTheMainRunLoopResponsive() {
        let wc = window()
        let gaps = mainRunLoopGaps(running: "yes '\(line)' | head -c 50000000", in: wc)
        #expect(gaps.command < gaps.quiet + 1, "the output adds no long hold of the main run loop (longest gap \(gaps.command) s, \(gaps.quiet) s for a command without output)")

        let transcript = wc.workspace.console.transcript
        let length = (transcript as NSString).length
        #expect(length <= ConsoleViewController.maxCharacters, "the transcript stays within its cap")
        #expect(length > 300_000, "…and holds the end of the output, not a fraction of it")
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.suffix(2).first?.hasPrefix("exit 0 · ") == true, "the exit line comes last, after all output")
        #expect(lines.suffix(3).first == Substring(line), "the last line of the output is complete")
        let other = lines.filter { $0 != Substring(line) }
        #expect(other.count <= 5, "nothing garbled: \(other.prefix(8))")
        #expect(showsItsEnd(transcriptView(wc)), "scrolled to the end of the output")
    }

    @Test func stopWorksDuringEndlessOutput() {
        let wc = window()
        let quiet = mainRunLoopGaps(running: "true", in: wc).quiet // and opens the console
        run("yes '\(line)'", in: wc)
        #expect(waitFor { wc.shell.isRunning })
        let heartbeat = Heartbeat()
        let flooding = Date()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let beatsPerSecond = Double(heartbeat.beats.count - 1) / Date().timeIntervalSince(flooding)
        #expect(beatsPerSecond > 5, "a 20 Hz timer keeps firing during the flood (\(beatsPerSecond) per second)")
        #expect(wc.shell.isRunning)
        #expect(wc.canPerform(.stopCommand))
        wc.perform(.stopCommand)
        #expect(waitFor(5) { !wc.shell.isRunning })
        let longestGap = heartbeat.stop()
        #expect(longestGap < quiet + 1, "the flood and its end add no long hold of the main run loop (longest gap \(longestGap) s, \(quiet) s for a command without output)")
        let transcript = wc.workspace.console.transcript
        #expect((transcript as NSString).length <= ConsoleViewController.maxCharacters)
        #expect(transcript.hasSuffix(" s\n") && transcript.contains("stopped (signal 2) · "), "the status line ends the transcript")
    }

    // MARK: What the transcript shows

    @Test func outputKeepsItsOrderAndStreamColours() {
        let wc = window()
        run("echo out; sleep 0.3; echo err >&2; sleep 0.3; echo more", in: wc)
        #expect(waitFor(10) { !wc.shell.isRunning })
        let text = wc.workspace.console.attributedTranscript
        let range = (text.string as NSString).range(of: "out\nerr\nmore\nexit 0")
        #expect(range.location != NSNotFound, "\(text.string)")
        guard range.location != NSNotFound else { return }
        func colour(_ offset: Int) -> NSColor? {
            text.attribute(.foregroundColor, at: range.location + offset, effectiveRange: nil) as? NSColor
        }
        #expect(colour(0) == .labelColor)
        #expect(colour(4) == .systemRed, "stderr stays red")
        #expect(colour(8) == .labelColor)
    }

    // MARK: Following the output

    @Test func consoleFollowsOutputThatOutgrowsIt() {
        let wc = window()
        run("echo hi", in: wc)
        #expect(waitFor(10) { !wc.shell.isRunning })
        let view = transcriptView(wc)
        wc.window?.layoutIfNeeded()
        #expect(view.bounds.height <= view.visibleRect.height + 1, "a short transcript fits")
        run("for i in {1..300}; do echo line $i; done; sleep 0.2; echo last", in: wc)
        #expect(waitFor(20) { !wc.shell.isRunning })
        #expect(showsItsEnd(view), "visible \(view.visibleRect) of \(view.bounds)")
    }

    /// Lines of very different lengths wrap to different heights, so the height of text
    /// that hasn't been laid out yet can only be estimated. The view must still end up at
    /// the end once the layout has caught up.
    @Test func staysAtTheEndWhenWrappedLinesAreLaidOutLater() {
        let wc = window()
        run("for i in {1..4000}; do print -r -- ${(l:$((i % 7 * 150 + 1))::x:)}; done", in: wc)
        #expect(waitFor(30) { !wc.shell.isRunning })
        let view = transcriptView(wc)
        #expect(showsItsEnd(view), "visible \(view.visibleRect) of \(view.bounds)")
        // What background layout does while the app idles: the rest gets its real height.
        let before = view.bounds.height
        view.layoutManager!.ensureLayout(for: view.textContainer!)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(view.bounds.height != before, "the estimate was off, as this test needs (\(before))")
        #expect(showsItsEnd(view), "visible \(view.visibleRect) of \(view.bounds)")
    }

    @Test func scrollingUpStopsFollowingUntilTheUserReturnsToTheEnd() throws {
        let wc = window()
        run("for i in {1..300}; do echo line $i; done", in: wc)
        #expect(waitFor(20) { !wc.shell.isRunning })
        let view = transcriptView(wc)
        let scroll = try #require(view.enclosingScrollView)
        #expect(showsItsEnd(view))

        // The user scrolls to the top to read.
        view.scroll(.zero)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        run("for i in {1..300}; do echo more $i; done", in: wc)
        #expect(waitFor(20) { !wc.shell.isRunning })
        wc.window?.layoutIfNeeded()
        #expect(view.visibleRect.minY < 1, "new output doesn't pull the view away")

        // …and back to the end.
        view.scrollToEndOfDocument(nil)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        run("for i in {1..300}; do echo again $i; done", in: wc)
        #expect(waitFor(20) { !wc.shell.isRunning })
        #expect(showsItsEnd(view))
    }
}
