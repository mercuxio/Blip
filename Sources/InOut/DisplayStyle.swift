import AppKit
import InOutCore
import SwiftUI

/// How the menu bar item renders. Both options show live throughput — a
/// static-glyph mode was dropped, since a monitor that displays nothing is
/// just a launcher for the panel.
enum DisplayStyle: String, CaseIterable, Identifiable {
    /// Two stacked rows, out over in, each led by an arrow.
    case rates
    /// A template sparkline of recent throughput.
    case sparkline

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rates: "Rates"
        case .sparkline: "Sparkline"
        }
    }
}

/// The default menu bar readout: two tightly stacked rows, upload above
/// download, each led by an arrow glyph.
///
/// This has to be a drawn image rather than a `VStack` of two `Text`s —
/// `MenuBarExtra` only renders `Text` and `Image` in its label, so a stacked
/// layout is not expressible as a view. Everything below is therefore hand-laid
/// out in AppKit.
enum StackedRates {
    private static let fontSize: CGFloat = 9
    private static let gap: CGFloat = 2
    /// Total strip height. The menu bar gives ~22pt of content space; 18 leaves
    /// a little breathing room above and below.
    private static let barHeight: CGFloat = 18

    /// Built fresh on each use rather than cached in a `static let`: `NSFont`
    /// is not `Sendable`, and this keeps it out of the drawing closure's
    /// captures entirely.
    private static func font() -> NSFont {
        .monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
    }

    private static func arrow(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            // Deliberately lighter and smaller than the digits: at equal weight
            // the arrowheads out-weigh the numbers and the eye lands on the
            // decoration instead of the value.
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: fontSize - 2, weight: .medium)
            )
    }

    /// The last image handed out, and the pair of strings it renders.
    ///
    /// `@MainActor` rather than lock-guarded because the only caller is a
    /// SwiftUI `body`, which is already main-actor isolated — so the cache needs
    /// no synchronisation and `NSImage` never has to be called `Sendable`.
    @MainActor private static var cached: (key: String, image: NSImage)?

    /// Keyed on the *rendered strings*, not the rates behind them.
    ///
    /// Those are different things far more often than they look. `reading`
    /// carries session totals as well as rates, so any traffic at all changes it
    /// every tick — while the two short strings the menu bar actually shows sit
    /// still for long stretches. Returning the identical `NSImage` instance on
    /// those ticks is the point: a freshly built image can never compare equal,
    /// so SwiftUI would tear the status item down and re-lay it out to display
    /// pixels it was already displaying.
    @MainActor
    static func image(rateIn: Double, rateOut: Double) -> NSImage {
        let up = ByteFormat.rate(rateOut)
        let down = ByteFormat.rate(rateIn)
        let key = up + "\n" + down
        if let cached, cached.key == key { return cached.image }

        // Sized to the widest string this can ever produce, with the values
        // right-aligned inside it. A width that tracked the current string
        // would shove every other menu bar item sideways once a second.
        let reference = ("999 MB/s" as NSString).size(withAttributes: [.font: font()]).width
        let arrowWidth = arrow("arrow.down")?.size.width ?? fontSize
        let width = (arrowWidth + gap + reference).rounded(.up)

        // Only Strings and CGFloats cross into the closure — no AppKit objects.
        // AppKit may re-invoke this handler off the main thread to redraw at a
        // different scale, so everything it captures has to be Sendable.
        let image = NSImage(size: NSSize(width: width, height: barHeight), flipped: false) { _ in
            drawRow(text: up, symbol: "arrow.up", onTop: true, width: width)
            drawRow(text: down, symbol: "arrow.down", onTop: false, width: width)
            return true
        }
        image.isTemplate = true
        cached = (key, image)
        return image
    }

    private static func drawRow(text raw: String, symbol: String, onTop: Bool, width: CGFloat) {
        let font = font()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        let text = raw as NSString
        let size = text.size(withAttributes: attributes)

        // Pack the rows by cap height, not line height: two 9pt line boxes are
        // ~22pt and would not fit, but digits and uppercase never descend, so
        // the boxes can overlap without the glyphs ever colliding.
        let baseline = onTop ? barHeight - font.capHeight - 1 : 1.5

        // draw(at:) places the bottom of the line box, so shift by the
        // descender (negative) to land the baseline where we want it.
        text.draw(
            at: NSPoint(x: width - size.width, y: baseline + font.descender),
            withAttributes: attributes
        )

        if let arrow = arrow(symbol) {
            let glyph = arrow.size
            arrow.draw(in: NSRect(x: 0, y: baseline - 1, width: glyph.width, height: glyph.height))
        }
    }
}

enum Sparkline {
    @MainActor private static var cached: (samples: [Double], size: NSSize, image: NSImage)?

    /// Draws recent throughput as a filled area chart sized for the menu bar.
    ///
    /// `isTemplate = true` is the important line: it hands the bitmap's alpha
    /// channel to AppKit as a mask, so the system tints it for light mode, dark
    /// mode, and the inverted look while the menu is open. Drawing an explicit
    /// black or white would break in two of those three states.
    ///
    /// Cached on the sampled window for the same reason `StackedRates` is: an
    /// idle machine appends zero to a window of zeros and gets an identical
    /// array back, and handing SwiftUI the same instance is what lets it skip
    /// the redraw. Comparing 42 doubles is far cheaper than the update it saves.
    @MainActor
    static func image(values: [Double], width: CGFloat = 42, height: CGFloat = 16) -> NSImage {
        let size = NSSize(width: width, height: height)
        let samples = Array(values.suffix(Int(width)))
        if let cached, cached.size == size, cached.samples == samples { return cached.image }
        // Scale to the window's own peak: absolute scaling would leave the
        // chart flat at everything below gigabit.
        let peak = max(samples.max() ?? 0, 1)

        let image = NSImage(size: size, flipped: false) { rect in
            guard samples.count > 1 else { return true }

            let inset: CGFloat = 1.5
            let usableHeight = rect.height - inset * 2
            let step = rect.width / CGFloat(samples.count - 1)

            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: inset))
            for (index, value) in samples.enumerated() {
                let normalized = min(value / peak, 1)
                let x = CGFloat(index) * step
                let y = inset + usableHeight * CGFloat(normalized)
                path.line(to: NSPoint(x: x, y: y))
            }
            path.line(to: NSPoint(x: rect.width, y: inset))
            path.close()

            NSColor.black.withAlphaComponent(0.85).setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        cached = (samples, size, image)
        return image
    }
}
