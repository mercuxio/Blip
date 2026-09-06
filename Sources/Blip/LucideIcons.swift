import SwiftUI

/// A Lucide glyph as a SwiftUI `Shape`.
///
/// Lucide draws on a 24x24 grid with y pointing down — the same convention
/// SwiftUI's `Path` uses — so the geometry below is transcribed straight from
/// the upstream SVG with no coordinate flip, and `path(in:)` only has to scale
/// and centre it. (The app-icon generator in Tools/ *does* flip, because
/// `NSBezierPath` is y-up.)
struct LucideIcon: Shape {
    /// Appends the glyph in Lucide's own 24-unit space.
    ///
    /// `@Sendable` because `Shape` refines `Sendable`, and a stored closure is
    /// the one member that doesn't get it for free. Every trace below is
    /// non-capturing, so the constraint is satisfied by construction.
    let trace: @Sendable (inout Path) -> Void

    func path(in rect: CGRect) -> Path {
        var path = Path()
        trace(&path)

        let scale = min(rect.width, rect.height) / Self.grid
        let placement = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -Self.grid / 2, y: -Self.grid / 2)
        return path.applying(placement)
    }

    static let grid: CGFloat = 24
    /// Lucide's own stroke width, in grid units.
    static let strokeUnits: CGFloat = 2
}

extension LucideIcon {
    /// lucide/icons/timer-reset.svg
    static var timerReset: LucideIcon {
        LucideIcon { path in
            // "M10 2h4" — the timer's crown.
            path.move(to: CGPoint(x: 10, y: 2))
            path.addLine(to: CGPoint(x: 14, y: 2))

            // "M12 14v-4" — the hand.
            path.move(to: CGPoint(x: 12, y: 14))
            path.addLine(to: CGPoint(x: 12, y: 10))

            // "M4 13a8 8 0 0 1 8-7 8 8 0 1 1-5.3 14L4 17.6"
            //
            // Two SVG arc commands, but all three points sit 8 units from
            // (12,14), so they describe one continuous sweep on a single circle
            // — which is what makes this expressible at all, since SwiftUI has
            // no elliptical-arc-to primitive, only centre-and-angle arcs.
            //
            // Both arcs carry sweep-flag 1 (increasing angle), so the second
            // simply continues past 360 rather than wrapping.
            let centre = CGPoint(x: 12, y: 14)
            let radius: CGFloat = 8
            let start = Angle(degrees: 187.125)  // atan2(13 - 14, 4 - 12)
            let end = Angle(degrees: 491.454)    // atan2(20 - 14, 6.7 - 12), + 360

            path.move(
                to: CGPoint(
                    x: centre.x + radius * cos(start.radians),
                    y: centre.y + radius * sin(start.radians)
                )
            )
            // `clockwise: false` means increasing angle. In a y-down space that
            // renders as clockwise on screen, so the flag reads as the opposite
            // of the result — verified by rendering, not by reasoning.
            path.addArc(
                center: centre,
                radius: radius,
                startAngle: start,
                endAngle: end,
                clockwise: false
            )
            path.addLine(to: CGPoint(x: 4, y: 17.6))

            // "M9 17H4v5" — the arrowhead the sweep points into.
            path.move(to: CGPoint(x: 9, y: 17))
            path.addLine(to: CGPoint(x: 4, y: 17))
            path.addLine(to: CGPoint(x: 4, y: 22))
        }
    }

    /// lucide/icons/coffee.svg
    static var coffee: LucideIcon {
        LucideIcon { path in
            // "M16 8a1 1 0 0 1 1 1v8a4 4 0 0 1-4 4H7a4 4 0 0 1-4-4V9a1 1 0 0 1
            //  1-1h14a4 4 0 1 1 0 8h-1" — the cup, as one unbroken subpath.
            //
            // Its four rounded corners are tangent arcs rather than centre-and-
            // angle ones: a tangent arc is specified by the corner it rounds, so
            // the awkward question of which way an arc sweeps never arises. The
            // SVG's radii are exactly the distance from each corner to its
            // neighbouring vertex, so every tangent point lands on a vertex.
            path.move(to: CGPoint(x: 16, y: 8))
            path.addArc(  // top-right lip
                tangent1End: CGPoint(x: 17, y: 8),
                tangent2End: CGPoint(x: 17, y: 17),
                radius: 1
            )
            path.addArc(  // bottom-right of the cup
                tangent1End: CGPoint(x: 17, y: 21),
                tangent2End: CGPoint(x: 7, y: 21),
                radius: 4
            )
            path.addArc(  // bottom-left of the cup
                tangent1End: CGPoint(x: 3, y: 21),
                tangent2End: CGPoint(x: 3, y: 9),
                radius: 4
            )
            path.addArc(  // top-left lip
                tangent1End: CGPoint(x: 3, y: 8),
                tangent2End: CGPoint(x: 18, y: 8),
                radius: 1
            )
            path.addLine(to: CGPoint(x: 18, y: 8))

            // The handle. Its endpoints are 8 apart on a radius of 4, so the arc
            // is an exact half-circle about (18,12) and the SVG's large-arc flag
            // carries no information — only the sweep decides which side it
            // bulges. Increasing angle passes through 0 degrees, i.e. rightwards.
            path.addArc(
                center: CGPoint(x: 18, y: 12),
                radius: 4,
                startAngle: .degrees(270),
                endAngle: .degrees(450),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: 17, y: 16))

            // "M6 2v2", "M10 2v2", "M14 2v2" — steam.
            for x in [6.0, 10.0, 14.0] as [CGFloat] {
                path.move(to: CGPoint(x: x, y: 2))
                path.addLine(to: CGPoint(x: x, y: 4))
            }
        }
    }

    /// lucide/icons/log-out.svg
    static var logOut: LucideIcon {
        LucideIcon { path in
            // "m16 17 5-5-5-5" — the arrowhead.
            path.move(to: CGPoint(x: 16, y: 17))
            path.addLine(to: CGPoint(x: 21, y: 12))
            path.addLine(to: CGPoint(x: 16, y: 7))

            // "M21 12H9" — its shaft.
            path.move(to: CGPoint(x: 21, y: 12))
            path.addLine(to: CGPoint(x: 9, y: 12))

            // "M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" — the open side of the
            // door, drawn as a bracket. Tangent arcs again for the two corners.
            path.move(to: CGPoint(x: 9, y: 21))
            path.addArc(
                tangent1End: CGPoint(x: 3, y: 21),
                tangent2End: CGPoint(x: 3, y: 5),
                radius: 2
            )
            path.addArc(
                tangent1End: CGPoint(x: 3, y: 3),
                tangent2End: CGPoint(x: 9, y: 3),
                radius: 2
            )
            path.addLine(to: CGPoint(x: 9, y: 3))
        }
    }
}

/// A Lucide glyph stroked at a given point size, keeping Lucide's proportions.
///
/// The stroke is derived from the size rather than fixed, because Lucide's
/// 2-unit width is a *fraction of the 24-unit grid*, not a point value: a
/// literal 2pt stroke would render a 13pt glyph nearly four times too heavy.
struct LucideGlyph: View {
    let icon: LucideIcon
    var size: CGFloat = 13
    /// Optical correction against the SF Symbols beside it, which carry a little
    /// more weight than Lucide at the same nominal size.
    var weight: CGFloat = 1.15
    /// Invisible margin added to the click target on every side.
    var hitSlop: CGFloat = 4

    private var lineWidth: CGFloat {
        LucideIcon.strokeUnits * size / LucideIcon.grid * weight
    }

    var body: some View {
        icon
            .stroke(
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
            .frame(width: size, height: size)
            .padding(hitSlop)
            // Without this, a stroked Shape hit-tests the *stroke* — here a
            // ~1.25pt hairline — so a click only registers when it lands exactly
            // on the drawn line and falls through the hollow middle of the glyph.
            // Rectangle() makes the whole padded box clickable, which is what an
            // icon button is expected to be.
            .contentShape(Rectangle())
    }
}
