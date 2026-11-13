import Foundation
import Testing
@testable import DrevoCore

/// SGR sequences (ESC [ … m) become styles; everything else is stripped as before.
@Suite struct TextStyleTests {
    let esc = "\u{1B}"

    /// The style after `parameters` (the text between `ESC [` and `m`), starting from `style`.
    func style(_ parameters: String, from style: TextStyle = .plain) -> TextStyle {
        var s = style
        Array(parameters.utf8).withUnsafeBufferPointer { s.apply(sgr: $0) }
        return s
    }

    func spans(_ text: String) -> [StyledText] {
        var s = ANSIStream()
        return s.spans(text)
    }

    // MARK: Parameters

    @Test func standardAndBrightColours() {
        #expect(style("31").foreground == .palette(1))
        #expect(style("37").foreground == .palette(7))
        #expect(style("90").foreground == .palette(8))
        #expect(style("97").foreground == .palette(15))
        #expect(style("40").background == .palette(0))
        #expect(style("47").background == .palette(7))
        #expect(style("100").background == .palette(8))
        #expect(style("107").background == .palette(15))
        #expect(style("31").background == nil)
        #expect(style("1;32;44") == TextStyle(foreground: .palette(2), background: .palette(4), bold: true))
    }

    @Test func colours256() {
        #expect(style("38;5;3").foreground == .palette(3), "the first 16 are the palette")
        #expect(style("38;5;12").foreground == .palette(12))
        #expect(style("38;5;16").foreground == .rgb(0, 0, 0))
        #expect(style("38;5;196").foreground == .rgb(255, 0, 0))
        #expect(style("38;5;110").foreground == .rgb(135, 175, 215))
        #expect(style("38;5;231").foreground == .rgb(255, 255, 255))
        #expect(style("48;5;232").background == .rgb(8, 8, 8))
        #expect(style("48;5;255").background == .rgb(238, 238, 238))
        #expect(style("38;5;196;1") == TextStyle(foreground: .rgb(255, 0, 0), bold: true), "parameters after the colour still count")
    }

    @Test func trueColour() {
        #expect(style("38;2;10;20;30").foreground == .rgb(10, 20, 30))
        #expect(style("48;2;255;128;0;4") == TextStyle(background: .rgb(255, 128, 0), underline: true))
        #expect(style("38;2;300;0;999").foreground == .rgb(255, 0, 255), "out-of-range components are clamped")
        #expect(style("38:2::10:20:30").foreground == .rgb(10, 20, 30), "the colon form, with its empty colour-space field")
        #expect(style("38:2:10:20:30").foreground == .rgb(10, 20, 30))
        #expect(style("48:5:196").background == .rgb(255, 0, 0))
    }

    @Test func defaultsAndReset() {
        let coloured = TextStyle(foreground: .palette(1), background: .palette(2), bold: true, underline: true)
        #expect(style("39", from: coloured) == TextStyle(background: .palette(2), bold: true, underline: true))
        #expect(style("49", from: coloured) == TextStyle(foreground: .palette(1), bold: true, underline: true))
        #expect(style("0", from: coloured) == .plain)
        #expect(style("", from: coloured) == .plain, "ESC [ m is a reset")
        #expect(style("0;31", from: coloured) == TextStyle(foreground: .palette(1)))
        #expect(style(";31", from: coloured) == TextStyle(foreground: .palette(1)), "an empty parameter is 0")
        #expect(TextStyle() == .plain && coloured != .plain)
    }

    @Test func attributesTurnOnAndOff() {
        let all = style("1;2;3;4;7")
        #expect(all == TextStyle(bold: true, dim: true, italic: true, underline: true, inverse: true))
        #expect(style("22", from: all) == TextStyle(italic: true, underline: true, inverse: true), "22 ends bold and dim")
        #expect(style("23", from: all).italic == false)
        #expect(style("24", from: all).underline == false)
        #expect(style("27", from: all).inverse == false)
        #expect(style("4:3").underline, "a curly underline is an underline")
        #expect(!style("4:0", from: all).underline)
    }

    @Test func unknownAndMalformedParametersChangeNothingElse() {
        #expect(style("5;8;9;53") == .plain, "blink, conceal, strike, overline: not rendered")
        #expect(style("31;5") == TextStyle(foreground: .palette(1)))
        #expect(style("1;38;5") == TextStyle(bold: true), "a colour cut short is ignored")
        #expect(style("38;2;1;2") == .plain)
        #expect(style("38;7;1") == .plain, "an unknown colour kind hides what follows: its length is unknown")
        #expect(style("99999999999999999999999;1") == TextStyle(bold: true), "a huge number is no overflow")
    }

    // MARK: Text

    @Test func plainTextIsOneSpan() {
        #expect(spans("hello\n") == [StyledText("hello\n")])
        #expect(spans("") == [])
        #expect(spans("a\r\nb\rc") == [StyledText("a\nbc")], "carriage returns go, as in ANSI.strip")
    }

    @Test func sgrSplitsTextIntoSpans() {
        let red = TextStyle(foreground: .palette(1), bold: true)
        #expect(spans("a \(esc)[1;31mred\(esc)[0m ok") == [StyledText("a "), StyledText("red", red), StyledText(" ok")])
        #expect(spans("\(esc)[4mu\(esc)[31mv") == [
            StyledText("u", TextStyle(underline: true)),
            StyledText("v", TextStyle(foreground: .palette(1), underline: true)),
        ], "styles add up until a reset")
        #expect(spans("\(esc)[31m\(esc)[0m") == [], "no text, no span")
        #expect(spans("a\(esc)[0mb\(esc)[mc") == [StyledText("abc")], "the same style on both sides is one span")
    }

    @Test func otherSequencesAreStillStripped() {
        let text = "a\(esc)[2K\(esc)[1;31mred\(esc)[0m \(esc)]0;title\(esc)\\b\(esc)]0;t\u{07}c\r\nd\(esc)Me→✓\(esc)[K\(esc)[?25l\(esc)[10;5H"
        let got = spans(text)
        #expect(got.map(\.text).joined() == ANSI.strip(text))
        #expect(got == [StyledText("a"), StyledText("red", TextStyle(foreground: .palette(1), bold: true)), StyledText(" bc\nde→✓")])
        #expect(spans("\(esc)[>4;2mx\(esc)[?1mx\(esc)[1 mx") == [StyledText("xxx")],
                "private-use and intermediate bytes: a CSI that ends in m but is no SGR")
    }

    // MARK: Chunks

    @Test func styleCarriesAcrossChunks() {
        var s = ANSIStream()
        #expect(s.spans("\(esc)[32mgreen") == [StyledText("green", TextStyle(foreground: .palette(2)))])
        #expect(s.spans(" still") == [StyledText(" still", TextStyle(foreground: .palette(2)))], "also on the plain-text fast path")
        #expect(s.spans("\(esc)[1m bold") == [StyledText(" bold", TextStyle(foreground: .palette(2), bold: true))])
        #expect(s.spans("\(esc)[0mplain") == [StyledText("plain")])
    }

    /// Flattens spans the way a reader sees them: one style per character.
    func perCharacter(_ spans: [StyledText]) -> [StyledText] {
        spans.flatMap { span in span.text.unicodeScalars.map { StyledText(String($0), span.style) } }
    }

    @Test func everySplitPointGivesTheSameStyledText() {
        let text = "a\(esc)[1;31mred\(esc)[0m \(esc)]0;title\(esc)\\b\(esc)]0;t\u{07}\(esc)[38;2;1;2;3;48;5;200mc\r\nd\(esc)Me→✓\(esc)[K\(esc)[4mu\(esc)[m."
        let expected = perCharacter(spans(text))
        #expect(expected.map(\.text).joined() == "ared bc\nde→✓u.")
        #expect(Set(expected.map(\.style)).count == 4)
        let scalars = Array(text.unicodeScalars)
        for cut in 0...scalars.count {
            var s = ANSIStream()
            let head = String(String.UnicodeScalarView(scalars[..<cut]))
            let tail = String(String.UnicodeScalarView(scalars[cut...]))
            #expect(perCharacter(s.spans(head) + s.spans(tail)) == expected, "split at \(cut)")
        }
        var s = ANSIStream()
        #expect(perCharacter(scalars.flatMap { s.spans(String($0)) }) == expected, "one character at a time")
    }

    @Test func unfinishedSequenceIsHeldBackAndAnEndlessOneIsText() {
        var s = ANSIStream()
        #expect(s.spans("done\(esc)[3") == [StyledText("done")], "nothing of the cut-off sequence leaks")
        var long = ANSIStream()
        let junk = "\(esc)]" + String(repeating: "x", count: 10_000)
        #expect(long.spans(junk).map(\.text).joined().count == 10_000)
        #expect(long.spans("y") == [StyledText("y")])
    }
}
