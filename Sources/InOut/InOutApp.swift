import InOutCore
import SwiftUI

@main
struct InOutApp: App {
    @State private var monitor = NetworkMonitor()
    @AppStorage("displayStyle") private var styleRaw = DisplayStyle.rates.rawValue

    private var style: Binding<DisplayStyle> {
        Binding(
            get: { DisplayStyle(rawValue: styleRaw) ?? .rates },
            set: { styleRaw = $0.rawValue }
        )
    }

    var body: some Scene {
        // `.window` rather than `.menu`: it renders an arbitrary SwiftUI view
        // in a popover instead of restricting us to menu items, which is what
        // lets the panel show a live two-column readout and selectable
        // addresses rather than a stack of inert menu rows.
        MenuBarExtra {
            PanelView(monitor: monitor, style: style)
        } label: {
            MenuBarLabel(monitor: monitor, style: style.wrappedValue)
        }
        .menuBarExtraStyle(.window)
    }
}
