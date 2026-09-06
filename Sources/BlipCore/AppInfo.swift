import Foundation

/// The app's own identity, as shown at the top of the settings menu.
public enum AppInfo {
    /// Composed from optionals rather than read from `Bundle` inside this
    /// function, so the assembly rules can be tested without a bundle: a
    /// `swift test` process has no Info.plist, and neither does `swift run`,
    /// so both fields here really can be absent at runtime.
    ///
    /// Deliberately the marketing version alone. `CFBundleVersion` is the
    /// other half of Apple's "1.0.0 (1)" convention, but that form belongs in
    /// an About panel: this is a one-line header a user reads in passing, and
    /// a build counter is a number only a developer can act on.
    public static func versionLabel(name: String?, shortVersion: String?) -> String {
        // Empty is treated as absent throughout: a plist key present but blank
        // should degrade the same way a missing one does, rather than render a
        // stray space or a bare version with nothing in front of it.
        let name = name.flatMap { $0.isEmpty ? nil : $0 } ?? "Blip"
        guard let shortVersion, !shortVersion.isEmpty else { return name }
        return "\(name) \(shortVersion)"
    }

    /// The running app's label, read once — an Info.plist cannot change under
    /// a running process.
    public static let current: String = {
        let info = Bundle.main.infoDictionary
        return versionLabel(
            // Display name first: it is what the app is called, while
            // CFBundleName is capped at 15 characters and may be abbreviated.
            name: info?["CFBundleDisplayName"] as? String
                ?? info?["CFBundleName"] as? String,
            shortVersion: info?["CFBundleShortVersionString"] as? String
        )
    }()
}
