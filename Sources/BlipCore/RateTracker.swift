import Foundation

/// A rate + running-total reading for one polling tick.
public struct TrafficReading: Sendable, Equatable {
    /// Bytes per second since the previous sample.
    public var rateIn: Double
    public var rateOut: Double
    /// Bytes accumulated since the tracker was created or last reset.
    public var totalIn: UInt64
    public var totalOut: UInt64

    public init(rateIn: Double, rateOut: Double, totalIn: UInt64, totalOut: UInt64) {
        self.rateIn = rateIn
        self.rateOut = rateOut
        self.totalIn = totalIn
        self.totalOut = totalOut
    }

    public static let zero = TrafficReading(rateIn: 0, rateOut: 0, totalIn: 0, totalOut: 0)
}

/// Turns cumulative per-interface kernel counters into rates and session totals.
///
/// Two rules drive the whole design:
///
/// 1. **Accumulate deltas; never subtract a start value.** `current - start`
///    breaks the moment an interface disappears, a counter resets, or the set
///    of monitored interfaces changes. Summing per-interface deltas survives
///    all three.
/// 2. **A negative delta means the counter reset, not that bytes were
///    un-sent.** Interfaces reset on link down/up and on wake. Contribute zero
///    and re-baseline rather than emitting a nonsense value.
///
/// Deliberately a plain value type with no clock of its own, so every rule
/// above is testable without waiting on real time or real traffic.
public struct RateTracker: Sendable {
    private var previous: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
    private var previousTime: TimeInterval?
    private var skipNextDelta = false

    public private(set) var totalIn: UInt64 = 0
    public private(set) var totalOut: UInt64 = 0

    public init() {}

    /// Discards the next sample's delta.
    ///
    /// Called on wake: the counters advanced while the machine was asleep, but
    /// attributing hours of accumulated bytes to one 1-second tick would spike
    /// the graph and inflate the session total with traffic the user never saw.
    public mutating func discardNextDelta() {
        skipNextDelta = true
    }

    /// Clears session totals. Baselines are kept, so the next tick still
    /// produces a sane rate.
    public mutating func resetTotals() {
        totalIn = 0
        totalOut = 0
    }

    /// Feeds one poll's worth of counters in and returns the current reading.
    ///
    /// - Parameters:
    ///   - counters: the interfaces being monitored this tick.
    ///   - time: a monotonic timestamp in seconds. Must come from a monotonic
    ///     clock (`ProcessInfo.systemUptime`), never `Date()` — a wall-clock
    ///     adjustment mid-session would otherwise produce a negative interval.
    @discardableResult
    public mutating func ingest(
        _ counters: [InterfaceCounters],
        at time: TimeInterval
    ) -> TrafficReading {
        var deltaIn: UInt64 = 0
        var deltaOut: UInt64 = 0
        var current: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        current.reserveCapacity(counters.count)

        for counter in counters {
            current[counter.name] = (counter.bytesIn, counter.bytesOut)
            // An interface we have not seen before contributes nothing this
            // tick; it only establishes a baseline. Otherwise plugging in a
            // dongle would register its entire lifetime history as one spike.
            guard let last = previous[counter.name] else { continue }
            if counter.bytesIn >= last.bytesIn {
                deltaIn += counter.bytesIn - last.bytesIn
            }
            if counter.bytesOut >= last.bytesOut {
                deltaOut += counter.bytesOut - last.bytesOut
            }
        }

        let elapsed = previousTime.map { time - $0 }
        previous = current
        previousTime = time

        // First sample of the session, a non-positive interval (clock moved
        // backwards), or the sample right after wake: baseline only.
        guard let elapsed, elapsed > 0, !skipNextDelta else {
            skipNextDelta = false
            return TrafficReading(rateIn: 0, rateOut: 0, totalIn: totalIn, totalOut: totalOut)
        }

        totalIn += deltaIn
        totalOut += deltaOut

        return TrafficReading(
            rateIn: Double(deltaIn) / elapsed,
            rateOut: Double(deltaOut) / elapsed,
            totalIn: totalIn,
            totalOut: totalOut
        )
    }
}
