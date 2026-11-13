import AppKit
import DrevoCore

/// How the console draws command output: the colours and fonts for a `TextStyle`.
@MainActor
enum ConsoleTextAttributes {
    static let fontSize: CGFloat = 11
    static let regularFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    /// nil if the system's monospaced font has no italic; the text is slanted instead.
    static let italicFont = italic(regularFont)
    static let boldItalicFont = italic(boldFont)
    /// The slant for italic text when the font has no italic face.
    static let obliqueness = 0.2
    /// How much of its colour dim text keeps.
    static let dimAlpha: CGFloat = 0.55

    private static func italic(_ font: NSFont) -> NSFont? {
        let converted = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        return NSFontManager.shared.traits(of: converted).contains(.italicFontMask) ? converted : nil
    }

    /// The text colour of output that sets none: stderr is red.
    static func defaultColor(isError: Bool) -> NSColor {
        isError ? .systemRed : .labelColor
    }

    /// The same styles come back all the time (a coloured listing has a handful), so
    /// their attributes are built once. Bounded, for output that never repeats a colour.
    private static var cache: [CacheKey: [NSAttributedString.Key: Any]] = [:]
    private static let cacheLimit = 512

    private struct CacheKey: Hashable {
        var style: TextStyle
        var isError: Bool
    }

    static func attributes(for style: TextStyle, isError: Bool) -> [NSAttributedString.Key: Any] {
        let key = CacheKey(style: style, isError: isError)
        if let known = cache[key] { return known }
        let made = makeAttributes(for: style, isError: isError)
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = made
        return made
    }

    private static func makeAttributes(for style: TextStyle, isError: Bool) -> [NSAttributedString.Key: Any] {
        var foreground: NSColor
        var background: NSColor?
        if style.inverse {
            background = style.foreground.map { color($0) } ?? defaultColor(isError: isError)
            foreground = style.background.map { color($0) } ?? .textBackgroundColor
        } else {
            background = style.background.map { color($0) }
            // Only text on the console's own background has to adapt to it.
            foreground = style.foreground.map { color($0, onConsoleBackground: background == nil) }
                ?? defaultColor(isError: isError)
        }
        if style.dim { foreground = dimmed(foreground) }

        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: foreground]
        if let background { attributes[.backgroundColor] = background }
        if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        let upright = style.bold ? boldFont : regularFont
        if style.italic {
            if let italic = style.bold ? boldItalicFont : italicFont {
                attributes[.font] = italic
            } else {
                attributes[.font] = upright
                attributes[.obliqueness] = obliqueness
            }
        } else {
            attributes[.font] = upright
        }
        return attributes
    }

    // MARK: Colours

    /// The colour for `color`. The 16 named ones differ between the light and the dark
    /// appearance, so that each reads well on the console's background in both. Black and
    /// white mean themselves when they are a background or lie on one the output chose
    /// ("black on yellow"); as text on the console's own background (`onConsoleBackground`)
    /// they become greys that can be read there — white text on a white console can't.
    static func color(_ color: TextStyle.Color, onConsoleBackground: Bool = false) -> NSColor {
        switch color {
        case .palette(let index):
            let i = Int(index) % palette.count
            return onConsoleBackground ? (textGreys[i] ?? palette[i]) : palette[i]
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
    }

    /// Black, red, green, yellow, blue, magenta, cyan, white, then their bright variants,
    /// as (light appearance, dark appearance).
    private static let palette: [NSColor] = [
        (0x000000, 0x000000), (0xC5221F, 0xF0625D), (0x188038, 0x5BC266), (0x9A6700, 0xD9B343),
        (0x1A56C4, 0x5C9DFF), (0xA626A4, 0xD67FD9), (0x0B7C8C, 0x4CC7D6), (0xC7C7C7, 0xC7C7C7),
        (0x666666, 0x666666), (0xE03E3A, 0xFF8A85), (0x2A9D4B, 0x7FE08A), (0xB58100, 0xF2D268),
        (0x3B78E7, 0x86B6FF), (0xC84FC6, 0xEAA0EC), (0x1499AD, 0x7DE0EC), (0xFFFFFF, 0xFFFFFF),
    ].map { dynamic(light: $0.0, dark: $0.1) }

    /// Black, white and their bright variants as text on the console's own background:
    /// in the order of prominence a terminal gives them, on either background.
    private static let textGreys: [Int: NSColor] = [
        0: dynamic(light: 0x000000, dark: 0x707070),
        7: dynamic(light: 0x4D4D4D, dark: 0xC8C8C8),
        8: dynamic(light: 0x7A7A7A, dark: 0x8C8C8C),
        15: dynamic(light: 0x1A1A1A, dark: 0xFFFFFF),
    ]

    private static func dynamic(light: Int, dark: Int) -> NSColor {
        func rgb(_ hex: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        let light = rgb(light), dark = rgb(dark)
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    /// `color` at `dimAlpha`, still following the appearance if `color` does.
    private static func dimmed(_ color: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved = color
            appearance.performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.sRGB) ?? color
            }
            return resolved.withAlphaComponent(resolved.alphaComponent * dimAlpha)
        }
    }
}
