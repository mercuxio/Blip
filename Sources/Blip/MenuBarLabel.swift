import BlipCore
import SwiftUI

struct MenuBarLabel: View {
    let monitor: NetworkMonitor
    let style: DisplayStyle

    var body: some View {
        switch style {
        case .rates:
            Image(nsImage: StackedRates.image(
                rateIn: monitor.reading.rateIn,
                rateOut: monitor.reading.rateOut
            ))
        case .sparkline:
            Image(nsImage: Sparkline.image(values: monitor.history))
        }
    }
}
