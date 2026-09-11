import AppKit
import BlipCore
import Observation
import SwiftUI

/// Owns the menu bar item and the panel that hangs off it.
///
/// This is hand-built AppKit rather than `MenuBarExtra` for one measured
/// reason. `MenuBarExtra` hosts its label in an `NSHostingView`, so every time
/// the readout changes AppKit re-solves that view's Auto Layout constraints
/// (`systemLayoutSizeFittingSize:`) and re-negotiates the item's width
/// (`-[NSStatusItem _adjustLength]`) before it can redraw. Both are pure
/// overhead here: `StackedRates` and `Sparkline` each return a constant-width
/// image, so the width provably cannot have changed.
///
/// An isolated probe doing nothing but updating a status item at 1 Hz:
///
///     MenuBarExtra (SwiftUI label)      1.47% CPU
///     NSStatusItem, variable length     1.24% CPU
///     NSStatusItem, fixed length        0.96% CPU
///
/// Blip itself, both builds running side by side on the same machine and the
/// same traffic, averaged over 7 minutes: **1.83% → 1.55%, a 15% saving.**
/// Take the real number, not the probe's 35% — and note the *absolute* saving is
/// smaller too (0.28 points against the probe's 0.51), which is not explained by
/// Blip's constant polling cost appearing in both arms. Left unchased.
///
/// What remains is AppKit's own replicant bookkeeping — it re-captures a bitmap
/// snapshot of the item through `CALayer renderInContext:` on every content
/// change — and is not reachable from here by any route. A control build
/// identical but for a frozen status item image measured **0.07%**, so very
/// nearly all of the remaining 1.55% is that redraw. The only lever left is how
/// often it happens, not how much it costs — which is what `redrawInterval`
/// below is, and where the rest of the saving comes from.
@MainActor
final class StatusItemController {
    private let monitor: NetworkMonitor
    private let settings: AppSettings
    private let item: NSStatusItem
    private let popover = NSPopover()

    /// Shortest wall time allowed between two menu bar repaints.
    ///
    /// The poll stays at 1 Hz — session totals have to be exact, and reading the
    /// counters is not what costs anything — but the repaint is what AppKit
    /// charges for, so it is decoupled and run at half the rate. The saving is
    /// linear in this number and is paid for in latency, not accuracy: the
    /// readout can lag reality by up to `redrawInterval`, and never lies.
    ///
    /// Quantizing the *value* was the obvious alternative and was measured and
    /// rejected; see the note on `StackedRates.image`.
    private static let redrawInterval: TimeInterval = 2

    /// Monotonic, like everything else that times things here: a wall-clock
    /// adjustment must not be able to park the readout for hours.
    private var lastRender: TimeInterval = -.greatestFiniteMagnitude
    private var pendingRender: Task<Void, Never>?

    init(monitor: NetworkMonitor, settings: AppSettings) {
        self.monitor = monitor
        self.settings = settings
        // A concrete length, not `.variableLength` — this is the whole point of
        // the class. `variableLength` makes AppKit re-derive the width from the
        // button's content on every change; both image builders return a
        // constant-width image, so that solve can only ever arrive at the width
        // it already had. `render()` keeps this in step if the image ever does
        // change size.
        item = NSStatusBar.system.statusItem(withLength: StackedRates.width)

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: PanelView(monitor: monitor, style: settings.styleBinding)
        )

        item.button?.target = self
        item.button?.action = #selector(togglePanel)

        render()
        observeMonitor()
        observeSettings()
    }

    isolated deinit {
        pendingRender?.cancel()
    }

    // MARK: - Rendering

    /// Pushes the current reading into the button, touching AppKit only when
    /// something it can see actually differs.
    ///
    /// Both image builders cache on their rendered content and hand back the
    /// *identical* `NSImage` on a miss-free tick, so the `!==` below is a real
    /// filter rather than a formality — it is what makes a tick with unchanged
    /// text cost nothing at all.
    private func render() {
        lastRender = ProcessInfo.processInfo.systemUptime
        guard let button = item.button else { return }

        let image: NSImage = switch settings.displayStyle {
        case .rates:
            StackedRates.image(rateIn: monitor.reading.rateIn, rateOut: monitor.reading.rateOut)
        case .sparkline:
            Sparkline.image(values: monitor.history)
        }

        guard button.image !== image else { return }
        button.image = image

        // Only on a real difference: assigning `length` at all re-lays out the
        // menu bar, so doing it unconditionally would hand back the saving the
        // fixed length just bought. In practice this fires once, when the
        // display style changes between the two constant widths.
        let width = image.size.width
        if abs(item.length - width) > 0.5 { item.length = width }
    }

    /// Renders now if the interval has elapsed, and otherwise *schedules* a
    /// render for the moment it does.
    ///
    /// The scheduled half is the part that matters. Simply dropping an early
    /// update would mean that when traffic stops — the last tick before the link
    /// goes quiet — the final value never reaches the menu bar, and the readout
    /// sits on a stale rate indefinitely. Deferring instead delays that value by
    /// at most `redrawInterval`; it never loses it. The task always reads the
    /// state as it is when it fires, so a burst of updates inside one interval
    /// collapses to a single repaint showing the newest value, which is exactly
    /// the coalescing this is for.
    private func renderIfDue() {
        let now = ProcessInfo.processInfo.systemUptime
        let due = lastRender + Self.redrawInterval

        guard now < due else {
            pendingRender?.cancel()
            pendingRender = nil
            render()
            return
        }

        // Already waiting: that task will pick up this change too, so leaving it
        // alone is what coalesces rather than a missed update.
        guard pendingRender == nil else { return }
        pendingRender = Task { [weak self] in
            try? await Task.sleep(for: .seconds(due - now))
            guard !Task.isCancelled, let self else { return }
            self.pendingRender = nil
            self.render()
        }
    }

    /// Re-arms after every fire: `withObservationTracking` is one-shot, so an
    /// observer that does not re-register stops seeing changes after the first.
    ///
    /// Split from `observeSettings` because the two want different latency.
    /// Traffic is throttled; a preference the user just picked is not.
    private func observeMonitor() {
        withObservationTracking {
            _ = monitor.reading
            _ = monitor.history
        } onChange: { [weak self] in
            // `onChange` runs *before* the new value is stored, so the read has
            // to be deferred to a later turn to see it.
            Task { @MainActor in
                guard let self else { return }
                self.renderIfDue()
                self.observeMonitor()
            }
        }
    }

    /// Unthrottled: switching between rates and sparkline has to look instant,
    /// and it happens once in a blue moon rather than once a second.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.displayStyle
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pendingRender?.cancel()
                self.pendingRender = nil
                self.render()
                self.observeSettings()
            }
        }
    }

    // MARK: - Panel

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            // Without this the panel opens behind the frontmost app and the
            // first click lands on that app instead of on the panel.
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
