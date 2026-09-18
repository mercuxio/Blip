// Writes the app icon as an Icon Composer bundle (Resources/AppIcon.icon). Run
// via `make icon`, which compiles it with `actool` into Resources/Assets.car
// and the fallback Resources/AppIcon.icns.
//
// An Icon Composer icon, not a flat .icns with its own rounded tile: macOS 26
// and later treat a flat icon as legacy and shrink it onto a grey tile. From
// the bundle the system draws the shape, the glass lighting, and the dark and
// tinted variants itself.
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

private enum Icon {
    /// Icon Composer's canvas. The fill covers all of it; the system applies
    /// the rounded mask, so nothing here draws a tile or corners.
    static let canvas = 1024
    /// Glyph size as a fraction of the canvas.
    static let glyphFraction: CGFloat = 0.60

    static let fillTop = "srgb:0.24300,0.27100,0.32500,1.00000"
    static let fillBottom = "srgb:0.08600,0.10200,0.12900,1.00000"
    static let stroke = NSColor(srgbRed: 0.965, green: 0.973, blue: 0.984, alpha: 1)
}

/// The glyph alone, on a transparent canvas, as the bundle's one layer.
private func renderGlyph() -> NSBitmapImageRep {
    let side = CGFloat(Icon.canvas)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Icon.canvas,
        pixelsHigh: Icon.canvas,
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
    context.shouldAntialias = true

    // Map the 24-unit glyph space onto the canvas, flipping y so the SVG's
    // downward axis lands the right way up in AppKit's upward one.
    let box = side * Icon.glyphFraction
    let scale = box / 24
    var transform = AffineTransform()
    transform.translate(x: side / 2 - box / 2, y: side / 2 + box / 2)
    transform.scale(x: scale, y: -scale)

    let glyph = networkGlyph()
    glyph.transform(using: transform)
    glyph.lineCapStyle = .round
    glyph.lineJoinStyle = .round
    // The system scales this one 1024 px layer down for small sizes itself.
    glyph.lineWidth = 2 * scale
    Icon.stroke.setStroke()
    glyph.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Output

private let manifest = """
{
  "fill" : {
    "linear-gradient" : [
      "\(Icon.fillTop)",
      "\(Icon.fillBottom)"
    ]
  },
  "groups" : [
    {
      "layers" : [ { "image-name" : "glyph.png", "name" : "glyph" } ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : true, "value" : 0.3 }
    }
  ],
  "supported-platforms" : { "squares" : [ "macOS" ] }
}

"""

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: GenerateIcon <AppIcon.icon>\n".utf8))
    exit(2)
}

let bundle = URL(fileURLWithPath: arguments[1])
let assets = bundle.appendingPathComponent("Assets")
try? FileManager.default.removeItem(at: bundle)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

guard let png = renderGlyph().representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to encode the glyph\n".utf8))
    exit(1)
}
try png.write(to: assets.appendingPathComponent("glyph.png"))
try Data(manifest.utf8).write(to: bundle.appendingPathComponent("icon.json"))

print("Wrote \(bundle.path)")
