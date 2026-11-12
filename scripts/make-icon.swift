// Draws the fman app icon into an .iconset folder (convert with `iconutil -c icns`).
// Usage: swift scripts/make-icon.swift build/AppIcon.iconset
//
// The design ("Glass panes", deep indigo): an indigo tile holding two panes. The left pane
// is solid white with a cursor row (the active pane); the right one is frosted glass.
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // The artwork is laid out on a 120-unit tile with a top-left origin. The tile is the
    // macOS 11+ icon body: 824 px inside a 1024 px canvas, which leaves room for the shadow.
    let s = size / 1024.0
    let unit = 824.0 / 120.0 * s
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: 100 * s + x * unit, y: 100 * s + (120 - y - h) * unit, width: w * unit, height: h * unit)
    }
    func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: rect(x, y, w, h), xRadius: radius * unit, yRadius: radius * unit)
    }
    func withShadow(alpha: CGFloat, blur: CGFloat, drop: CGFloat, _ draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color(0x0B0638, alpha)
        shadow.shadowBlurRadius = blur * unit
        shadow.shadowOffset = NSSize(width: 0, height: -drop * unit)
        shadow.set()
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Tile: indigo gradient, a soft glow along the top, a thin light rim.
    let tile = rounded(0, 0, 120, 120, 27)
    withShadow(alpha: 0.35, blur: 3.5, drop: 1.5) {
        color(0x2A1F9C).setFill()
        tile.fill()
    }
    NSGradient(starting: color(0x6C7CF5), ending: color(0x2A1F9C))!.draw(in: tile, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    color(0xFFFFFF, 0.16).setFill()
    NSBezierPath(ovalIn: rect(-16, -26, 152, 60)).fill()
    NSGraphicsContext.restoreGraphicsState()
    let rim = rounded(0.75, 0.75, 118.5, 118.5, 26.25)
    rim.lineWidth = 1.5 * unit
    color(0xFFFFFF, 0.22).setStroke()
    rim.stroke()

    // Active pane: solid white, lifted off the tile.
    withShadow(alpha: 0.45, blur: 4, drop: 3) {
        color(0xFFFFFF).setFill()
        rounded(21, 24, 37, 70, 8.5).fill()
    }

    // Inactive pane: frosted glass with a bright edge.
    color(0xFFFFFF, 0.24).setFill()
    rounded(62, 24, 37, 70, 8.5).fill()
    let edge = rounded(62.75, 24.75, 35.5, 68.5, 7.75)
    edge.lineWidth = 1.5 * unit
    color(0xFFFFFF, 0.75).setStroke()
    edge.stroke()

    // Rows. Below 64 px they blur into noise, so only the cursor row is kept, enlarged.
    let detailed = size >= 64
    if detailed {
        color(0xCDCBEC).setFill()
        for (y, w) in [(32.0, 25.0), (57, 25), (67, 18), (77, 22)] {
            rounded(27, y, w, 5, 2.5).fill()
        }
        color(0xFFFFFF, 0.62).setFill()
        for (y, w) in [(32.0, 25.0), (44, 18), (56, 22), (68, 15)] {
            rounded(68, y, w, 5, 2.5).fill()
        }
    }
    color(0x4A3FD6).setFill()
    if detailed {
        rounded(25, 42, 29, 10, 4.5).fill()
    } else {
        rounded(26, 40, 27, 16, 5).fill()
    }
    return rep
}

let sizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    let data = drawIcon(size: px).representation(using: .png, properties: [:])!
    try data.write(to: outDir.appendingPathComponent("\(name).png"))
}
print("Wrote \(sizes.count) images to \(outDir.path)")
