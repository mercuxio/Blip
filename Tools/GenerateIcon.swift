// Renders the app icon into a .iconset directory. Run via `make icon`, which
// then hands the directory to `iconutil` to produce Resources/AppIcon.icns.
//
// The glyph is Lucide's "network" icon, whose geometry is transcribed verbatim
// below from lucide/icons/network.svg — a 24x24 viewBox stroked at 2 units with
// round caps and joins. Drawing it with AppKit rather than rasterising the SVG
// keeps the toolchain to what ships with macOS: no librsvg, no node.

import AppKit
import Foundation

// MARK: - Geometry

/// The Lucide glyph, in its own 24x24 coordinate space with y pointing *down*
/// as SVG defines it. The caller flips it.
private func networkGlyph() -> NSBezierPath {
    let path = NSBezierPath()

    // Three 6x6 nodes: two below, one above.
    for origin in [NSPoint(x: 16, y: 16), NSPoint(x: 2, y: 16), NSPoint(x: 9, y: 2)] {
        path.append(
            NSBezierPath(
                roundedRect: NSRect(x: origin.x, y: origin.y, width: 6, height: 6),
                xRadius: 1,
                yRadius: 1
            )
        )
    }

    // The bus: "M5 16v-3a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v3".
    //
    // Its two corners are quarter-circle arcs in the SVG. They are rebuilt here
    // with tangent arcs (`appendArc(from:to:radius:)`) rather than centre-and-
    // angle arcs, because a tangent arc is defined purely by the corner it
    // rounds — so it stays correct under the vertical flip below, where a
    // sweep direction would have silently inverted.
    path.move(to: NSPoint(x: 5, y: 16))
    path.appendArc(from: NSPoint(x: 5, y: 12), to: NSPoint(x: 18, y: 12), radius: 1)
    path.appendArc(from: NSPoint(x: 19, y: 12), to: NSPoint(x: 19, y: 16), radius: 1)
    path.line(to: NSPoint(x: 19, y: 16))

    // The drop from the bus to the top node: "M12 12V8".
    path.move(to: NSPoint(x: 12, y: 12))
    path.line(to: NSPoint(x: 12, y: 8))

    return path
}

// MARK: - Rendering

private enum Tile {
    /// Proportions of the macOS icon grid: the rounded square occupies the
    /// middle ~80% of the canvas, leaving the margin the system expects for
    /// shadows and optical alignment against other icons.
    static let inset: CGFloat = 100.0 / 1024.0
    static let cornerRadius: CGFloat = 185.0 / 1024.0
    /// Glyph size as a fraction of the tile.
    static let glyphFraction: CGFloat = 0.60

    static let top = NSColor(srgbRed: 0.243, green: 0.271, blue: 0.325, alpha: 1)
    static let bottom = NSColor(srgbRed: 0.086, green: 0.102, blue: 0.129, alpha: 1)
    static let stroke = NSColor(srgbRed: 0.965, green: 0.973, blue: 0.984, alpha: 1)
}

private func render(pixels: Int) -> NSBitmapImageRep {
    let side = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.shouldAntialias = true

    let inset = side * Tile.inset
    let tile = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = side * Tile.cornerRadius

    let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    NSGradient(starting: Tile.bottom, ending: Tile.top)?.draw(in: tilePath, angle: 90)

    // Map the 24-unit glyph space onto the tile, flipping y so the SVG's
    // downward axis lands the right way up in AppKit's upward one.
    let box = tile.width * Tile.glyphFraction
    let scale = box / 24
    var transform = AffineTransform()
    transform.translate(x: tile.midX - box / 2, y: tile.midY + box / 2)
    transform.scale(x: scale, y: -scale)

    let glyph = networkGlyph()
    glyph.transform(using: transform)
    glyph.lineCapStyle = .round
    glyph.lineJoinStyle = .round
    // Clamped so the stroke never falls below roughly a pixel: at 16pt the
    // honest 2-unit width works out under 0.7px and antialiases into grey mush.
    glyph.lineWidth = max(2 * scale, 1.2)
    Tile.stroke.setStroke()
    glyph.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Output

/// The exact set `iconutil` expects; anything missing makes it refuse the
/// directory outright.
private let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: GenerateIcon <output.iconset>\n".utf8))
    exit(2)
}

let directory = URL(fileURLWithPath: arguments[1])
try? FileManager.default.removeItem(at: directory)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

for variant in variants {
    guard let data = render(pixels: variant.pixels).representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write(Data("failed to encode \(variant.name)\n".utf8))
        exit(1)
    }
    try data.write(to: directory.appendingPathComponent(variant.name))
}

print("Wrote \(variants.count) images to \(directory.path)")
