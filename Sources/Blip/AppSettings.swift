import BlipCore
import Observation
import SwiftUI

/// The one preference Blip persists, in the one place that owns it.
///
/// `@AppStorage` would be the obvious choice and is not available here: it is a
/// SwiftUI property wrapper, and since `StatusItemController` reads the display
/// style from outside any view, the value has to live somewhere both a view and
/// plain AppKit can reach. `@Observable` gives both — SwiftUI tracks it through
/// `styleBinding`, and the controller tracks the same property through
/// `withObservationTracking`.
///
/// The key and its string values are unchanged from the `@AppStorage` version,
/// so an existing install keeps whatever it had selected.
@MainActor
@Observable
final class AppSettings {
    private static let styleKey = "displayStyle"

    var displayStyle: DisplayStyle {
        didSet {
            guard displayStyle != oldValue else { return }
            UserDefaults.standard.set(displayStyle.rawValue, forKey: Self.styleKey)
        }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.styleKey)
        displayStyle = raw.flatMap(DisplayStyle.init(rawValue:)) ?? .rates
    }

    /// Handed to `PanelView`, which still wants a `Binding`. Reading
    /// `wrappedValue` inside a `body` touches `displayStyle`, so SwiftUI
    /// registers the dependency and the picker stays live.
    var styleBinding: Binding<DisplayStyle> {
        Binding(get: { self.displayStyle }, set: { self.displayStyle = $0 })
    }
}
