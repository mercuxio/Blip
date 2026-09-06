import BlipCore
import SwiftUI

struct PanelView: View {
    let monitor: NetworkMonitor
    @Binding var style: DisplayStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RateHeader(reading: monitor.reading)
            Divider()
            InterfaceSection(
                name: monitor.interfaceName,
                addresses: monitor.addresses,
                degraded: monitor.usingDegradedCounters
            )
            Divider()
            PublicAddressSection(
                state: monitor.publicAddress,
                refresh: { monitor.refreshPublicAddress(force: true) }
            )
            Divider()
            FooterBar(monitor: monitor, style: $style)
        }
        .frame(width: 340)
        .onAppear { monitor.refreshPublicAddress() }
    }
}

// MARK: - Header

private struct RateHeader: View {
    let reading: TrafficReading

    var body: some View {
        HStack(spacing: 0) {
            RateColumn(
                symbol: "arrow.down",
                tint: .blue,
                rate: reading.rateIn,
                total: reading.totalIn
            )
            Divider().frame(height: 44)
            RateColumn(
                symbol: "arrow.up",
                tint: .orange,
                rate: reading.rateOut,
                total: reading.totalOut
            )
        }
        .padding(.vertical, 14)
    }
}

private struct RateColumn: View {
    let symbol: String
    let tint: Color
    let rate: Double
    let total: UInt64

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tint)
                Text(ByteFormat.rate(rate))
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
            Text("\(ByteFormat.total(total)) this session")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Interface

private struct InterfaceSection: View {
    let name: String?
    let addresses: [String]
    let degraded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name ?? "No active interface")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if degraded {
                    Label("Approximate", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .help("The accurate kernel counter failed its startup check; totals may wrap.")
                }
            }
            if addresses.isEmpty {
                Text("No address assigned")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(addresses, id: \.self) { address in
                    Text(address)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Public address

private struct PublicAddressSection: View {
    let state: PublicAddressState
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Public IP")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Look up again")
                .disabled(state == .looking)
                .opacity(state == .looking ? 0.35 : 1)
            }

            switch state {
            case .unknown, .looking:
                Text("Looking up…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            case .resolved(let found):
                ForEach(found, id: \.self) { address in
                    Text(address)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            case .unavailable:
                // Distinguished from "no address" above: the interface may be
                // perfectly healthy and the lookup still fail behind a captive
                // portal or a blocked endpoint.
                Text("Couldn't reach the lookup service")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Footer

private struct FooterBar: View {
    /// Force-unwrapped because the literal is a compile-time constant: if it
    /// ever fails to parse, that is a typo to catch on the first launch, not a
    /// runtime condition to handle.
    static let supportURL = URL(string: "https://buymeacoffee.com/benjamintan")!

    let monitor: NetworkMonitor
    @Binding var style: DisplayStyle

    /// Mirrors the system's login-item registration for the duration of the
    /// menu. It is re-read rather than stored, so a change made in System
    /// Settings is picked up the next time the panel opens.
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        // Spacing is small because every control below carries its own 4pt of
        // invisible hit slop; 2 + 4 + 4 puts the *visible* gap back at 10.
        HStack(spacing: 2) {
            Menu {
                Picker("Menu bar", selection: $style) {
                    ForEach(DisplayStyle.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                Picker("Measure", selection: Binding(
                    get: { monitor.policy },
                    set: { monitor.policy = $0 }
                )) {
                    ForEach(InterfacePolicy.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                Toggle("Start at login", isOn: Binding(
                    get: { launchAtLogin },
                    // The system is the source of truth, so the toggle follows
                    // what actually happened rather than what was asked for: a
                    // refused registration snaps back instead of lying.
                    set: { wanted in
                        LaunchAtLogin.set(wanted)
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                ))

                Divider()
                // A bare Text in a macOS menu renders as a disabled row, which
                // is what this wants to be: visible, greyed, unclickable. Last
                // rather than first because it is a footnote, not a heading —
                // the controls are what the menu is opened for.
                Text(AppInfo.current)
            } label: {
                // Matches the padded box LucideGlyph builds, so all four footer
                // controls are the same size and sit on the same rhythm.
                Image(systemName: "gearshape")
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }

            Button { monitor.resetSession() } label: {
                LucideGlyph(icon: .timerReset, size: 13)
            }
            .buttonStyle(.plain)
            .help("Reset session totals")

            // `Link` rather than a Button calling NSWorkspace: it hands the URL
            // to the user's default browser through the same path a clicked link
            // anywhere else takes, and carries the pointing-hand cursor for free.
            Link(destination: FooterBar.supportURL) {
                LucideGlyph(icon: .coffee, size: 13)
            }
            .buttonStyle(.plain)
            .help("Buy me a coffee")

            Spacer()

            Button { NSApplication.shared.terminate(nil) } label: {
                LucideGlyph(icon: .logOut, size: 13)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit Blip")
        }
        // 10 horizontal and 5 vertical, plus each control's own 4pt of slop,
        // reproduces the 14/9 insets the text buttons used to need.
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}
