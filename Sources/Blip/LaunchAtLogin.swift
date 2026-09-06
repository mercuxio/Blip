import Foundation
import ServiceManagement

/// Registers the app as a login item.
///
/// `SMAppService.mainApp` is the modern replacement for
/// `SMLoginItemSetEnabled` and the old `~/Library/LaunchAgents` plist: the
/// system stores the registration itself, keyed to the bundle's code signature,
/// so there is no state of ours to persist. That is also why this deliberately
/// has no `@AppStorage` mirror — a stored bool could disagree with reality the
/// moment the user toggles the item off in System Settings, and the system's
/// own `status` is the only answer that can't go stale.
enum LaunchAtLogin {
    /// What the system currently thinks.
    ///
    /// `.requiresApproval` is its own case, not a failure: macOS registers the
    /// item but leaves it disabled until the user approves it under
    /// Login Items, so the app is registered *and* won't launch.
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    /// Registers or unregisters, returning whether the system agreed.
    ///
    /// Failure here is ordinary rather than exceptional — an unapproved or
    /// re-signed bundle can be refused — so the caller gets a Bool to reconcile
    /// its toggle against, and the error is logged rather than thrown.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("Blip: login item \(enabled ? "register" : "unregister") failed: \(error)")
            return false
        }
    }
}
