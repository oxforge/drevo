import AppKit
import Testing
@testable import DrevoCore
@testable import DrevoUI

/// The console shows the colours and text attributes a command asks for (SGR sequences).
@MainActor
@Suite(.serialized) struct ConsoleColourTests {
    let fx = Fixture()

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

    /// The attributes of the transcript where `word` begins — where it is last seen: the
    /// line that echoes the command has the word too, before the output.
    func attributes(of word: String, in text: NSAttributedString) -> [NSAttributedString.Key: Any] {
        let range = (text.string as NSString).range(of: word, options: .backwards)
        guard range.location != NSNotFound else {
            Issue.record("“\(word)” is not in the transcript: \(text.string)")
            return [:]
        }
        var whole = NSRange()
        let found = text.attributes(at: range.location, longestEffectiveRange: &whole, in: NSRange(location: 0, length: text.length))
        #expect(NSMaxRange(whole) >= NSMaxRange(range), "“\(word)” is in one style")
        return found
    }

    func isBold(_ font: Any?) -> Bool {
        (font as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
    }

    /// `color` as it is drawn in the light or the dark appearance.
    func resolved(_ color: NSColor, _ appearance: NSAppearance.Name) -> NSColor {
        var out = color
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return out
    }

    /// WCAG relative luminance.
    func luminance(_ c: NSColor) -> CGFloat {
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }

    func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    // MARK: Styles to attributes

    @Test func aBatchShowsEachRunInItsStyle() {
        let console = ConsoleViewController()
        console.append(OutputBacklog.Batch(runs: [
            .init(text: "plain ", isError: false),
            .init(text: "red ", isError: false, style: TextStyle(foreground: .palette(1))),
            .init(text: "bold ", isError: false, style: TextStyle(bold: true)),
            .init(text: "under ", isError: false, style: TextStyle(underline: true)),
            .init(text: "exact ", isError: false, style: TextStyle(foreground: .rgb(10, 20, 30), background: .rgb(200, 210, 220))),
            .init(text: "onblue ", isError: false, style: TextStyle(background: .palette(4))),
            .init(text: "oops ", isError: true),
            .init(text: "warn ", isError: true, style: TextStyle(foreground: .palette(3), bold: true)),
            .init(text: "errunder\n", isError: true, style: TextStyle(underline: true)),
        ]))
        #expect(console.transcript == "plain red bold under exact onblue oops warn errunder\n")
        let text = console.attributedTranscript

        let plain = attributes(of: "plain", in: text)
        #expect(plain[.foregroundColor] as? NSColor == .labelColor)
        #expect(plain[.backgroundColor] == nil && plain[.underlineStyle] == nil)
        #expect(plain[.font] as? NSFont == .monospacedSystemFont(ofSize: 11, weight: .regular))

        let red = attributes(of: "red", in: text)
        #expect(red[.foregroundColor] as? NSColor == ConsoleTextAttributes.color(.palette(1)))
        #expect(!isBold(red[.font]))

        let bold = attributes(of: "bold", in: text)
        #expect(isBold(bold[.font]))
        #expect(bold[.foregroundColor] as? NSColor == .labelColor)
        #expect((bold[.font] as? NSFont)?.isFixedPitch == true, "still monospaced")

        let under = attributes(of: "under", in: text)
        #expect(under[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)

        let exact = attributes(of: "exact", in: text)
        #expect(exact[.foregroundColor] as? NSColor == NSColor(srgbRed: 10 / 255, green: 20 / 255, blue: 30 / 255, alpha: 1))
        #expect(exact[.backgroundColor] as? NSColor == NSColor(srgbRed: 200 / 255, green: 210 / 255, blue: 220 / 255, alpha: 1))

        let onBlue = attributes(of: "onblue", in: text)
        #expect(onBlue[.backgroundColor] as? NSColor == ConsoleTextAttributes.color(.palette(4)))
        #expect(onBlue[.foregroundColor] as? NSColor == .labelColor)

        #expect(attributes(of: "oops", in: text)[.foregroundColor] as? NSColor == .systemRed, "stderr without a colour stays red")
        let warn = attributes(of: "warn", in: text)
        #expect(warn[.foregroundColor] as? NSColor == ConsoleTextAttributes.color(.palette(3)), "a colour stderr asks for wins")
        #expect(isBold(warn[.font]))
        let errUnder = attributes(of: "errunder", in: text)
        #expect(errUnder[.foregroundColor] as? NSColor == .systemRed, "an attribute alone leaves stderr red")
        #expect(errUnder[.underlineStyle] != nil)
    }

    @Test func inverseSwapsTextAndBackground() {
        let green = ConsoleTextAttributes.color(.palette(2)), blue = ConsoleTextAttributes.color(.palette(4))
        let both = ConsoleTextAttributes.attributes(for: TextStyle(foreground: .palette(2), background: .palette(4), inverse: true), isError: false)
        #expect(both[.foregroundColor] as? NSColor == blue)
        #expect(both[.backgroundColor] as? NSColor == green)
        let bare = ConsoleTextAttributes.attributes(for: TextStyle(inverse: true), isError: false)
        #expect(bare[.foregroundColor] as? NSColor == .textBackgroundColor)
        #expect(bare[.backgroundColor] as? NSColor == .labelColor)
        let error = ConsoleTextAttributes.attributes(for: TextStyle(inverse: true), isError: true)
        #expect(error[.backgroundColor] as? NSColor == .systemRed)
    }

    @Test func dimAndItalic() {
        let dim = ConsoleTextAttributes.attributes(for: TextStyle(foreground: .palette(2), dim: true), isError: false)
        let full = ConsoleTextAttributes.color(.palette(2))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let dimmed = resolved(dim[.foregroundColor] as! NSColor, appearance), base = resolved(full, appearance)
            #expect(abs(dimmed.alphaComponent - ConsoleTextAttributes.dimAlpha) < 0.01)
            #expect(abs(dimmed.redComponent - base.redComponent) < 0.01 && abs(dimmed.greenComponent - base.greenComponent) < 0.01,
                    "the same colour, fainter, in \(appearance.rawValue)")
        }
        let plainDim = ConsoleTextAttributes.attributes(for: TextStyle(dim: true), isError: false)
        #expect(resolved(plainDim[.foregroundColor] as! NSColor, .aqua).alphaComponent < resolved(.labelColor, .aqua).alphaComponent)

        let italic = ConsoleTextAttributes.attributes(for: TextStyle(italic: true), isError: false)
        let slanted = (italic[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } ?? false
        #expect(slanted || italic[.obliqueness] != nil, "an italic face, or the upright one slanted")
        let boldItalic = ConsoleTextAttributes.attributes(for: TextStyle(bold: true, italic: true), isError: false)
        #expect(isBold(boldItalic[.font]))
    }

    // MARK: Palette

    @Test func namedColoursReadWellOnTheConsoleInBothAppearances() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let background = resolved(.textBackgroundColor, appearance)
            for index in UInt8(0)..<16 {
                let text = resolved(ConsoleTextAttributes.color(.palette(index), onConsoleBackground: true), appearance)
                let ratio = contrast(text, background)
                #expect(ratio >= 3, "colour \(index) in \(appearance.rawValue): contrast \(ratio)")
            }
        }
    }

    @Test func namedColoursKeepTheirHue() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            func c(_ i: UInt8) -> NSColor { resolved(ConsoleTextAttributes.color(.palette(i), onConsoleBackground: true), appearance) }
            for bright in [UInt8(0), 8] {
                let red = c(1 + bright), green = c(2 + bright), yellow = c(3 + bright)
                let blue = c(4 + bright), magenta = c(5 + bright), cyan = c(6 + bright)
                #expect(red.redComponent > red.greenComponent && red.redComponent > red.blueComponent)
                #expect(green.greenComponent > green.redComponent && green.greenComponent > green.blueComponent)
                #expect(yellow.redComponent > yellow.blueComponent && yellow.greenComponent > yellow.blueComponent)
                #expect(blue.blueComponent > blue.redComponent && blue.blueComponent > blue.greenComponent)
                #expect(magenta.redComponent > magenta.greenComponent && magenta.blueComponent > magenta.greenComponent)
                #expect(cyan.greenComponent > cyan.redComponent && cyan.blueComponent > cyan.redComponent)
            }
        }
        let red = ConsoleTextAttributes.color(.palette(1))
        #expect(resolved(red, .aqua) != resolved(red, .darkAqua), "darker on white, lighter on black")
    }

    @Test func blackAndWhiteMeanThemselvesOffTheConsoleBackground() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            #expect(luminance(resolved(ConsoleTextAttributes.color(.palette(0)), appearance)) < 0.01)
            #expect(luminance(resolved(ConsoleTextAttributes.color(.palette(15)), appearance)) > 0.99)
        }
        // "Black on yellow": on a background the output chose, the text is not adapted.
        let badge = ConsoleTextAttributes.attributes(for: TextStyle(foreground: .palette(0), background: .palette(3)), isError: false)
        #expect(badge[.foregroundColor] as? NSColor == ConsoleTextAttributes.color(.palette(0)))
        let text = ConsoleTextAttributes.attributes(for: TextStyle(foreground: .palette(15)), isError: false)
        #expect(text[.foregroundColor] as? NSColor == ConsoleTextAttributes.color(.palette(15), onConsoleBackground: true))
        #expect(luminance(resolved(text[.foregroundColor] as! NSColor, .aqua)) < 0.2, "white text on a white console is dark")
    }

    // MARK: Real commands

    @Test func aCommandsColoursReachTheTranscript() {
        let wc = window()
        // The green underline is set in one chunk and still on in the next, after an update.
        run(#"printf '\033[1;31mfail\033[0m plain \033]0;title\007\033[2K'; printf '\033[4;32mgreen '; sleep 0.3; printf 'still\033[0m after\n'; printf '\033[38;5;196mloud\033[m\n' >&2"#, in: wc)
        #expect(waitFor(10) { !wc.shell.isRunning })
        let text = wc.workspace.console.attributedTranscript
        #expect(text.string.contains("fail plain green still after\n"), "sequences are not shown: \(text.string)")

        let fail = attributes(of: "fail", in: text)
        #expect(fail[.foregroundColor] as? NSColor == ConsoleTextAttributes.color(.palette(1)))
        #expect(isBold(fail[.font]))
        let plain = attributes(of: "plain", in: text)
        #expect(plain[.foregroundColor] as? NSColor == .labelColor)
        #expect(!isBold(plain[.font]))
        for word in ["green", "still"] {
            let green = attributes(of: word, in: text)
            #expect(green[.foregroundColor] as? NSColor == ConsoleTextAttributes.color(.palette(2)), "\(word)")
            #expect(green[.underlineStyle] != nil, "\(word)")
        }
        #expect(attributes(of: "after", in: text)[.underlineStyle] == nil)
        #expect(attributes(of: "loud", in: text)[.foregroundColor] as? NSColor == NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        #expect(attributes(of: "exit 0", in: text)[.foregroundColor] as? NSColor == .secondaryLabelColor, "the status line is not coloured by the output")
    }

    @Test func aStyleLeftOnDoesNotLeakIntoTheNextCommand() {
        let wc = window()
        run(#"printf '\033[35mmagenta\n'"#, in: wc)
        #expect(waitFor(10) { !wc.shell.isRunning })
        run("echo second", in: wc)
        #expect(waitFor(10) { !wc.shell.isRunning })
        let text = wc.workspace.console.attributedTranscript
        #expect(attributes(of: "magenta", in: text)[.foregroundColor] as? NSColor == ConsoleTextAttributes.color(.palette(5)))
        #expect(attributes(of: "second\n", in: text)[.foregroundColor] as? NSColor == .labelColor)
    }

    // MARK: Fast coloured output

    /// 50 MB where every line changes colour twice: the backlog hands the console tens of
    /// thousands of short runs per update instead of one long one. (Whether any of it is
    /// skipped depends on how fast the reader parses, so that is not checked.)
    @Test func aColouredFloodLeavesTheMainRunLoopResponsive() {
        let wc = window()
        run(#"yes $'\e[1;32mthe quick\e[0m brown fox' | head -c 50000000"#, in: wc)
        let heartbeat = Heartbeat(every: 0.02)
        #expect(waitFor(60) { !wc.shell.isRunning })
        let longestGap = heartbeat.stop()
        #expect(longestGap < 1, "the main run loop was never held for long (longest gap \(longestGap) s)")

        let text = wc.workspace.console.attributedTranscript
        #expect(text.length <= ConsoleViewController.maxCharacters, "the transcript stays within its cap")
        #expect(text.length > 300_000, "…and holds the end of the output, not a fraction of it")
        let lines = text.string.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.suffix(2).first?.hasPrefix("exit 0 · ") == true, "the exit line comes last, after all output")
        let other = lines.filter { $0 != "the quick brown fox" }
        #expect(other.count <= 5, "nothing garbled: \(other.prefix(8))")

        // The last whole line of output.
        let last = (text.string as NSString).range(of: "the quick brown fox\n", options: .backwards)
        #expect(last.location != NSNotFound)
        guard last.location != NSNotFound else { return }
        let quick = text.attributes(at: last.location, effectiveRange: nil)
        #expect(quick[.foregroundColor] as? NSColor == ConsoleTextAttributes.color(.palette(2)))
        #expect(isBold(quick[.font]))
        let brown = text.attributes(at: last.location + 10, effectiveRange: nil)
        #expect(brown[.foregroundColor] as? NSColor == .labelColor)
        #expect(!isBold(brown[.font]))
    }

    @Test func aColouredBatchKeepsTheCapAndTheSkippedNote() {
        let console = ConsoleViewController()
        console.begin(command: "flood", directory: fx.url)
        console.append("an unfinished line", isError: false)
        let green = TextStyle(foreground: .palette(2))
        let count = ConsoleViewController.backlogLimit / 20
        let runs = (0..<count).flatMap { _ in
            [OutputBacklog.Run(text: "0123456789", isError: false, style: green), .init(text: "abcdefghi\n", isError: false)]
        }
        let start = Date()
        console.append(OutputBacklog.Batch(runs: runs, skipped: true))
        #expect(Date().timeIntervalSince(start) < 1, "\(runs.count) runs in one update took \(Date().timeIntervalSince(start)) s")
        let text = console.attributedTranscript
        #expect(text.length <= ConsoleViewController.maxCharacters)
        #expect(text.string.components(separatedBy: "… output skipped …").count - 1 == 1)
        let note = (text.string as NSString).range(of: "… output skipped …\n")
        #expect(text.attribute(.foregroundColor, at: note.location, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
        #expect(text.attribute(.foregroundColor, at: NSMaxRange(note), effectiveRange: nil) as? NSColor == ConsoleTextAttributes.color(.palette(2)),
                "the note's dim colour ends with the note")
        #expect(text.attribute(.foregroundColor, at: text.length - 1, effectiveRange: nil) as? NSColor == .labelColor)
        #expect(text.attribute(.foregroundColor, at: text.length - 20, effectiveRange: nil) as? NSColor == ConsoleTextAttributes.color(.palette(2)))
    }
}
