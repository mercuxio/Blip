import AppKit
import Foundation
import BlipCore
import Observation

/// What we currently know about the public address.
///
/// A four-state enum rather than `String?` because the panel has to distinguish
/// "still asking" from "asked and the network said no" — collapsing those into
/// one empty value is how a UI ends up claiming an outage during a slow lookup.
enum PublicAddressState: Equatable {
    case unknown
    case looking
    case resolved([String])
    case unavailable
}

/// Owns the polling loop and every piece of state the UI renders.
///
/// `@MainActor` on the whole class, with the kernel read pushed onto a detached
/// task. That is the inverse of the usual advice, and deliberate: the state is
/// tiny and read exclusively by SwiftUI, so main-actor isolation removes an
/// entire class of data race, while the one call that could actually block —
/// the per-interface sysctl sweep — is the only thing that leaves the main
/// thread.
@MainActor
@Observable
final class NetworkMonitor {
    // MARK: Published state

    private(set) var reading: TrafficReading = .zero
    /// Recent combined throughput, oldest first, for the sparkline.
    private(set) var history: [Double] = []
    private(set) var interfaceName: String?
    private(set) var addresses: [String] = []
    private(set) var publicAddress: PublicAddressState = .unknown
    /// True when the accurate counter path failed its launch sanity check and
    /// we fell back to the lossy one. Surfaced in the panel rather than hidden.
    private(set) var usingDegradedCounters = false

    var policy: InterfacePolicy = .primary {
        didSet { refreshInterface(force: true) }
    }

    // MARK: Internals

    static let historyLength = 60

    /// How long a resolved public address is trusted before the panel bothers
    /// the endpoint again. Residential addresses change on the order of days,
    /// so anything shorter is pure noise; a genuine change (VPN, new network)
    /// invalidates the cache directly rather than waiting this out.
    private static let publicAddressTTL: TimeInterval = 600

    private var tracker = RateTracker()
    private let counterSource: any CounterSource

    private var pollTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var addressRefreshCountdown = 0

    private var publicAddressTask: Task<Void, Never>?
    private var publicAddressCheckedAt: TimeInterval?

    /// True once something has actually asked for the public address.
    ///
    /// The lookup is deliberately on demand — it is the one number here that
    /// costs somebody else a request — so nothing may fetch it before the panel
    /// has been opened at least once. Past that point the interest is
    /// established, and keeping the answer alive is no longer speculative.
    private var publicAddressRequested = false

    /// Ticks until a failed lookup is retried, and the delay that seeds it.
    ///
    /// Waking races the interface coming back up, so the first attempt after a
    /// wake routinely fails on a network that is healthy two seconds later.
    /// Without a retry that failure is permanent until somebody presses the
    /// refresh button. The doubling is what keeps the other side of it from
    /// being a merely offline machine asking four times a minute, forever.
    private var publicAddressRetryCountdown = 0
    private var publicAddressRetryDelay = 0
    private static let publicAddressFirstRetryTicks = 15
    private static let publicAddressMaximumRetryTicks = 900

    /// Ephemeral, short-timeout, cache-defeating. Ephemeral so the lookup
    /// leaves no cookies or on-disk cache behind; cache-defeating so the
    /// refresh button actually re-asks rather than replaying a stored 200.
    private let lookupSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    init() {
        let (source, degraded) = CounterSourceSelector.choose()
        counterSource = source
        usingDegradedCounters = degraded
        refreshInterface(force: true)
        start()
    }

    // `isolated` because a plain deinit is nonisolated even on a @MainActor
    // class — the last reference can be dropped from any thread — and the task
    // handle is main-actor state.
    isolated deinit {
        pollTask?.cancel()
        publicAddressTask?.cancel()
    }

    // MARK: Lifecycle

    private func start() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                // Sleeping *after* the sample means the first reading lands
                // immediately at launch instead of a second late.
                try? await Task.sleep(for: .seconds(1))
            }
        }

        // Counters keep advancing across sleep. Without this, the first tick
        // after waking attributes hours of background traffic to one second.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tracker.discardNextDelta()
                self?.refreshInterface(force: true)
            }
        }
    }

    // MARK: Polling

    private func tick() async {
        let source = counterSource
        let rows = await Task.detached(priority: .utility) { source.read() }.value

        let selected = NetworkInterfaces.select(
            from: rows, policy: policy, primary: interfaceName
        )
        // Monotonic: a wall-clock adjustment mid-session must not be able to
        // produce a negative interval and a nonsensical rate.
        let now = ProcessInfo.processInfo.systemUptime
        let sample = tracker.ingest(selected, at: now)

        // Assign only on a real change. `@Observable` fires on every assignment
        // regardless of equality, and each fire invalidates the menu bar item —
        // so an idle machine was paying for a full status-item redraw once a
        // second to display the same "0 B/s" it already displayed.
        if sample != reading {
            reading = sample
        }

        // Re-resolve every tick so switching Wi-Fi to Ethernet is picked up
        // rather than leaving us watching a NIC that stopped carrying traffic.
        refreshInterface()

        if publicAddressRetryCountdown > 0 {
            publicAddressRetryCountdown -= 1
            if publicAddressRetryCountdown == 0 {
                refreshPublicAddress(force: true)
            }
        }

        // Deliberately unguarded, unlike `reading` above: this is a time series,
        // so a repeated value still has to advance it or a burst would sit on
        // screen forever instead of ageing off over the window. Only the
        // sparkline style reads `history`, so in the default rates style no
        // observer is registered on it and this costs no view update.
        history.append(sample.rateIn + sample.rateOut)
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
    }

    /// Resolving the *name* is a single SCDynamicStore lookup and cheap enough
    /// to do every second. Resolving *addresses* walks every address of every
    /// interface, so it only runs when the interface changed — or every 15
    /// ticks, to catch a new DHCP lease on an unchanged interface.
    private func refreshInterface(force: Bool = false) {
        let name = NetworkInterfaces.primaryName()
        let changed = name != interfaceName
        addressRefreshCountdown -= 1

        guard force || changed || addressRefreshCountdown <= 0 else {
            return
        }
        interfaceName = name
        addresses = name.map { NetworkInterfaces.addresses(for: $0) } ?? []
        addressRefreshCountdown = 15

        // Switching interface — or bringing a VPN up or down, which is the same
        // event as far as SCDynamicStore is concerned — almost always changes
        // the public address, so the cached one is now a lie. Drop it and let
        // the next panel open re-ask.
        if changed {
            publicAddressCheckedAt = nil
            if publicAddressRequested {
                // Re-ask rather than blanking. `PanelView`'s `onAppear` fires
                // once for the life of the MenuBarExtra content view, not on
                // every open, so a `.unknown` parked here is never resolved by
                // anything: the panel sits on "Looking up…" until the refresh
                // button is pressed. Waking is exactly this case, because the
                // interface goes away and comes back.
                refreshPublicAddress(force: true)
            } else {
                publicAddress = .unknown
            }
        }
    }

    // MARK: Public address

    /// Resolves the public address, unless a fresh answer is already in hand.
    ///
    /// Driven by the panel appearing rather than by the 1 Hz poll: this is the
    /// one number here that costs somebody else a network request, so it is
    /// fetched when someone is actually looking at it.
    func refreshPublicAddress(force: Bool = false) {
        publicAddressRequested = true
        guard publicAddressTask == nil else { return }

        if !force, case .resolved = publicAddress, let checked = publicAddressCheckedAt,
           ProcessInfo.processInfo.systemUptime - checked < Self.publicAddressTTL {
            return
        }

        publicAddress = .looking
        publicAddressTask = Task { [weak self] in
            guard let self else { return }
            // `defer` rather than a trailing assignment: the cancellation check
            // below returns early, and leaving the handle set there would wedge
            // the feature permanently — the guard above would refuse every
            // future lookup because a task it thinks is running never finished.
            defer { publicAddressTask = nil }
            let session = lookupSession

            // Concurrently, not in sequence: on a v4-only network the v6 lookup
            // can only fail, and making the user wait out that timeout before
            // the v4 answer appears would be the common case, not the rare one.
            async let four = Self.lookup(PublicAddress.ipv4Endpoint, session: session)
            async let six = Self.lookup(PublicAddress.ipv6Endpoint, session: session)
            let found = await [four, six].compactMap { $0 }

            guard !Task.isCancelled else { return }
            if found.isEmpty {
                publicAddress = .unavailable
                publicAddressRetryDelay = min(
                    max(publicAddressRetryDelay * 2, Self.publicAddressFirstRetryTicks),
                    Self.publicAddressMaximumRetryTicks
                )
                publicAddressRetryCountdown = publicAddressRetryDelay
            } else {
                publicAddress = .resolved(found)
                publicAddressRetryDelay = 0
                publicAddressRetryCountdown = 0
            }
            publicAddressCheckedAt = ProcessInfo.processInfo.systemUptime
        }
    }

    /// `nonisolated` so the request and the parse never touch the main actor;
    /// every failure — transport, non-200, or a body that is not an address —
    /// collapses to nil, because the panel has exactly one way to say "no".
    private nonisolated static func lookup(_ url: URL, session: URLSession) async -> String? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return PublicAddress.parse(data)
        } catch {
            return nil
        }
    }

    // MARK: Actions

    func resetSession() {
        tracker.resetTotals()
        reading = TrafficReading(rateIn: reading.rateIn, rateOut: reading.rateOut, totalIn: 0, totalOut: 0)
        history.removeAll()
    }
}
