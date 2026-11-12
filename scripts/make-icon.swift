// Draws the fman app icon into an .iconset folder (convert with `iconutil -c icns`).
// Usage: swift scripts/make-icon.swift build/AppIcon.iconset
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024.0
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
    }

    // Squircle body with a soft shadow, macOS 11+ grid (824pt body inside 1024 canvas).
    let body = r(100, 100, 824, 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor(calibratedRed: 0.16, green: 0.30, blue: 0.80, alpha: 1).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.29, green: 0.56, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.20, green: 0.33, blue: 0.86, alpha: 1),
        NSColor(calibratedRed: 0.27, green: 0.18, blue: 0.70, alpha: 1),
    ])!
    gradient.draw(in: bodyPath, angle: -70)

    // Two panes.
    let paneColor = NSColor.white.withAlphaComponent(0.96)
    let leftPane = r(190, 250, 290, 520)
    let rightPane = r(544, 250, 290, 520)
    for pane in [leftPane, rightPane] {
        let p = NSBezierPath(roundedRect: pane, xRadius: 46 * s, yRadius: 46 * s)
        paneColor.setFill()
        p.fill()
    }

    // Rows: folder glyph + bar.
    func rows(in pane: NSRect, highlight: Int) {
        let rowH: CGFloat = 78 * s
        for i in 0..<5 {
            let y = pane.maxY - 60 * s - CGFloat(i + 1) * rowH + 18 * s
            if i == highlight {
                let hl = NSRect(x: pane.minX + 18 * s, y: y - 14 * s, width: pane.width - 36 * s, height: rowH - 6 * s)
                NSColor(calibratedRed: 0.24, green: 0.47, blue: 0.98, alpha: 1).setFill()
                NSBezierPath(roundedRect: hl, xRadius: 18 * s, yRadius: 18 * s).fill()
            }
            let selected = i == highlight
            let folder = NSRect(x: pane.minX + 40 * s, y: y, width: 44 * s, height: 34 * s)
            (selected ? NSColor.white : NSColor(calibratedRed: 0.36, green: 0.65, blue: 1.0, alpha: 1)).setFill()
            NSBezierPath(roundedRect: folder, xRadius: 7 * s, yRadius: 7 * s).fill()
            let tab = NSRect(x: folder.minX, y: folder.maxY - 4 * s, width: 20 * s, height: 10 * s)
            NSBezierPath(roundedRect: tab, xRadius: 4 * s, yRadius: 4 * s).fill()
            let bar = NSRect(x: folder.maxX + 20 * s, y: y + 9 * s, width: pane.width - 150 * s - CGFloat(i % 3) * 30 * s, height: 16 * s)
            (selected ? NSColor.white.withAlphaComponent(0.9) : NSColor(calibratedWhite: 0.70, alpha: 1)).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 8 * s, yRadius: 8 * s).fill()
        }
    }
    rows(in: leftPane, highlight: 1)
    rows(in: rightPane, highlight: -1)

    // Arrow from left pane to right pane.
    let arrow = NSBezierPath()
    let cy = 610 * s
    arrow.move(to: NSPoint(x: 420 * s, y: cy + 26 * s))
    arrow.line(to: NSPoint(x: 560 * s, y: cy + 26 * s))
    arrow.line(to: NSPoint(x: 560 * s, y: cy + 62 * s))
    arrow.line(to: NSPoint(x: 640 * s, y: cy))
    arrow.line(to: NSPoint(x: 560 * s, y: cy - 62 * s))
    arrow.line(to: NSPoint(x: 560 * s, y: cy - 26 * s))
    arrow.line(to: NSPoint(x: 420 * s, y: cy - 26 * s))
    arrow.close()
    NSGraphicsContext.saveGraphicsState()
    let arrowShadow = NSShadow()
    arrowShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    arrowShadow.shadowBlurRadius = 12 * s
    arrowShadow.shadowOffset = NSSize(width: 0, height: -4 * s)
    arrowShadow.set()
    NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.16, alpha: 1).setFill()
    arrow.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
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
