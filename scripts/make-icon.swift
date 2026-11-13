// Draws the Drevo app icon into an .iconset folder (convert with `iconutil -c icns`).
// Usage: swift scripts/make-icon.swift build/AppIcon.iconset
//
// The design ("Sprouting root", deep indigo): an indigo tile holding a small folder tree.
// The root row is green and sprouts two leaves ("drevo" means tree); a connector leads
// down to the child rows, the first of which is the selected one (solid white).
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

    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: 100 * s + x * unit, y: 100 * s + (120 - y) * unit)
    }
    /// A leaf growing from `base` to `tip`, bulging to the sides given by the control points.
    func leaf(base: (CGFloat, CGFloat), tip: (CGFloat, CGFloat),
              out: (CGFloat, CGFloat), back: (CGFloat, CGFloat)) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: point(base.0, base.1))
        path.curve(to: point(tip.0, tip.1), controlPoint1: point(out.0, base.1), controlPoint2: point(tip.0, out.1))
        path.curve(to: point(base.0, base.1), controlPoint1: point(back.0, tip.1), controlPoint2: point(base.0, back.1))
        path.close()
        return path
    }
    func stroke(_ points: [(CGFloat, CGFloat)], width: CGFloat, _ strokeColor: NSColor) {
        let path = NSBezierPath()
        path.move(to: point(points[0].0, points[0].1))
        for p in points.dropFirst() { path.line(to: point(p.0, p.1)) }
        path.lineWidth = width * unit
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        strokeColor.setStroke()
        path.stroke()
    }

    let green = color(0x9BD45A), lightGreen = color(0xC9EDA0), connector = color(0xB9B4F2)
    let faded = color(0xFFFFFF, 0.55)

    // Below 64 px three thin rows blur into noise, so the small sizes keep the root, its
    // sprout and two rows, all drawn heavier.
    if size >= 64 {
        stroke([(34, 52), (34, 98), (46, 98)], width: 4, connector)
        stroke([(34, 64), (46, 64)], width: 4, connector)
        stroke([(34, 81), (46, 81)], width: 4, connector)

        stroke([(42, 38), (42, 28)], width: 4, green)
        green.setFill()
        leaf(base: (42, 33), tip: (27, 19), out: (32, 27), back: (37, 25)).fill()
        lightGreen.setFill()
        leaf(base: (42, 29), tip: (58, 14), out: (52, 23), back: (48, 20)).fill()

        withShadow(alpha: 0.4, blur: 3, drop: 2) {
            green.setFill()
            rounded(24, 36, 52, 14, 7).fill()
            color(0xFFFFFF).setFill()
            rounded(52, 58, 42, 12, 6).fill()
        }
        faded.setFill()
        rounded(52, 75, 30, 12, 6).fill()
        rounded(52, 92, 38, 12, 6).fill()
    } else {
        stroke([(36, 58), (36, 96), (50, 96)], width: 8, connector)
        stroke([(36, 72), (50, 72)], width: 8, connector)

        stroke([(45, 40), (45, 28)], width: 7, green)
        green.setFill()
        leaf(base: (45, 34), tip: (22, 13), out: (30, 25), back: (37, 22)).fill()
        lightGreen.setFill()
        leaf(base: (45, 30), tip: (69, 9), out: (60, 21), back: (54, 18)).fill()

        green.setFill()
        rounded(20, 38, 60, 20, 10).fill()
        color(0xFFFFFF).setFill()
        rounded(56, 63, 44, 18, 9).fill()
        faded.setFill()
        rounded(56, 87, 44, 18, 9).fill()
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
