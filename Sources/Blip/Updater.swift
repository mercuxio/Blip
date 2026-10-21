import Foundation
import Sparkle

/// Wraps Sparkle so the rest of the app sees one observable switch.
///
/// Updates come from the appcast named by `SUFeedURL` in Info.plist and are
/// verified against `SUPublicEDKey`; Sparkle refuses anything whose EdDSA
/// signature does not match, so a compromised feed alone cannot push code.
///
/// The switch is Sparkle's own, not a mirror of it. Sparkle persists it in user
/// defaults, so there is deliberately no second copy here to drift out of step —
/// the same reasoning as `LaunchAtLogin`. It starts **off** (`SUEnableAutomaticChecks`
/// is false in Info.plist), which is what keeps "Blip contacts nothing until you
/// ask it to" true: with the switch off Sparkle never touches the network.
@MainActor
@Observable
final class Updater {
    @ObservationIgnored private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    /// `access`/`withMutation` rather than a stored property because the truth
    /// lives inside Sparkle; this only tells `@Observable` when it was read and
    /// when it changed so SwiftUI redraws the tick.
    var automaticallyChecks: Bool {
        get { access(keyPath: \.automaticallyChecks); return controller.updater.automaticallyChecksForUpdates }
        set {
            withMutation(keyPath: \.automaticallyChecks) { controller.updater.automaticallyChecksForUpdates = newValue }
        }
    }
}
