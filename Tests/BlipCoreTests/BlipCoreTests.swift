import Foundation
import Testing
@testable import BlipCore

private let up = UInt32(0x1)          // IFF_UP
private let loopback = UInt32(0x8)    // IFF_LOOPBACK

private func iface(
    _ name: String, in bytesIn: UInt64, out bytesOut: UInt64, flags: UInt32 = up
) -> InterfaceCounters {
    InterfaceCounters(name: name, bytesIn: bytesIn, bytesOut: bytesOut, flags: flags)
}

// MARK: - RateTracker

@Suite("RateTracker")
struct RateTrackerTests {
    @Test("The first sample only establishes a baseline")
    func firstSampleIsBaselineOnly() {
        var tracker = RateTracker()
        let reading = tracker.ingest([iface("en0", in: 1_000_000, out: 500_000)], at: 100)

        #expect(reading.rateIn == 0)
        #expect(reading.rateOut == 0)
        #expect(reading.totalIn == 0)
        #expect(reading.totalOut == 0)
    }

    @Test("A steady delta over a known interval becomes a rate")
    func steadyDeltaBecomesRate() {
        var tracker = RateTracker()
        tracker.ingest([iface("en0", in: 1_000, out: 500)], at: 100)
        let reading = tracker.ingest([iface("en0", in: 3_000, out: 1_500)], at: 102)

        #expect(reading.rateIn == 1_000)   // 2000 bytes over 2 seconds
        #expect(reading.rateOut == 500)
        #expect(reading.totalIn == 2_000)
        #expect(reading.totalOut == 1_000)
    }

    @Test("A counter that goes backwards contributes zero, not a negative rate")
    func counterResetContributesZero() {
        var tracker = RateTracker()
        tracker.ingest([iface("en0", in: 10_000, out: 10_000)], at: 100)
        tracker.ingest([iface("en0", in: 12_000, out: 11_000)], at: 101)
        // Link bounced; the kernel counter restarted from zero.
        let reading = tracker.ingest([iface("en0", in: 300, out: 100)], at: 102)

        #expect(reading.rateIn == 0)
        #expect(reading.rateOut == 0)
        // The earlier legitimate delta survives; the reset adds nothing.
        #expect(reading.totalIn == 2_000)
        #expect(reading.totalOut == 1_000)

        // And the tracker re-baselines rather than staying stuck.
        let next = tracker.ingest([iface("en0", in: 1_300, out: 600)], at: 103)
        #expect(next.rateIn == 1_000)
        #expect(next.totalIn == 3_000)
    }

    @Test("Deltas from several interfaces are summed")
    func multipleInterfacesAreSummed() {
        var tracker = RateTracker()
        tracker.ingest([iface("en0", in: 100, out: 100), iface("en1", in: 200, out: 200)], at: 10)
        let reading = tracker.ingest(
            [iface("en0", in: 400, out: 300), iface("en1", in: 700, out: 500)], at: 11
        )

        #expect(reading.rateIn == 800)    // 300 + 500
        #expect(reading.rateOut == 500)   // 200 + 300
    }

    @Test("An interface appearing mid-session does not dump its history into one tick")
    func newInterfaceIsBaselinedNotCounted() {
        var tracker = RateTracker()
        tracker.ingest([iface("en0", in: 100, out: 100)], at: 10)
        // A dongle is plugged in carrying a lifetime counter of 9 GB.
        let reading = tracker.ingest(
            [iface("en0", in: 200, out: 200), iface("en5", in: 9_000_000_000, out: 1_000)], at: 11
        )

        #expect(reading.rateIn == 100)
        #expect(reading.totalIn == 100)
    }

    @Test("The post-wake sample is discarded")
    func wakeDiscardsOneDelta() {
        var tracker = RateTracker()
        tracker.ingest([iface("en0", in: 1_000, out: 1_000)], at: 100)
        tracker.discardNextDelta()
        // Woke up after an hour asleep; counters advanced by 500 MB.
        let reading = tracker.ingest([iface("en0", in: 500_001_000, out: 1_000)], at: 101)

        #expect(reading.rateIn == 0)
        #expect(reading.totalIn == 0)

        // The tick after that is normal again.
        let next = tracker.ingest([iface("en0", in: 500_002_000, out: 1_000)], at: 102)
        #expect(next.rateIn == 1_000)
    }

    @Test("Time moving backwards yields no rate rather than a negative one")
    func nonMonotonicTimeIsIgnored() {
        var tracker = RateTracker()
        tracker.ingest([iface("en0", in: 1_000, out: 1_000)], at: 100)
        let reading = tracker.ingest([iface("en0", in: 5_000, out: 5_000)], at: 99)

        #expect(reading.rateIn == 0)
        #expect(reading.rateOut == 0)
    }

    @Test("Resetting clears totals but keeps the baseline")
    func resetKeepsBaseline() {
        var tracker = RateTracker()
        tracker.ingest([iface("en0", in: 1_000, out: 1_000)], at: 100)
        tracker.ingest([iface("en0", in: 3_000, out: 3_000)], at: 101)
        tracker.resetTotals()

        let reading = tracker.ingest([iface("en0", in: 4_000, out: 3_500)], at: 102)
        #expect(reading.totalIn == 1_000)
        #expect(reading.rateIn == 1_000)   // not re-baselined, so still a real rate
    }
}

// MARK: - Counter source health

@Suite("Counter source selection")
struct CounterSourceSelectionTests {
    @Test("Healthy ifmib values are not mistaken for sanitized ones")
    func healthySourceIsKept() {
        let ifmib = [
            iface("en0", in: 5_000_000_001, out: 900_000_003),
            iface("en1", in: 3_000_000_007, out: 400_000_011),
        ]
        let iflist2 = [
            iface("en0", in: 705_032_704, out: 899_999_744),
            iface("en1", in: 305_032_192, out: 399_998_976),
        ]
        #expect(CounterSourceSelector.ifMibLooksSanitized(ifmib: ifmib, iflist2: iflist2) == false)
    }

    @Test("ifmib matching iflist2 exactly, on 1 KiB boundaries, is treated as sanitized")
    func sanitizedSourceIsDetected() {
        // Every value here is an exact multiple of 1024, as the rtsock path
        // reports them.
        let rows = [
            iface("en0", in: 705_033_216, out: 899_999_744),
            iface("en1", in: 305_033_216, out: 399_998_976),
        ]
        #expect(CounterSourceSelector.ifMibLooksSanitized(ifmib: rows, iflist2: rows))
    }

    @Test("A single busy interface is not enough evidence to demote the source")
    func oneInterfaceIsInsufficientEvidence() {
        let rows = [iface("en0", in: 705_033_216, out: 899_999_744)]
        #expect(CounterSourceSelector.ifMibLooksSanitized(ifmib: rows, iflist2: rows) == false)
    }

    @Test("Idle interfaces carry no signal and cannot trigger a demotion")
    func idleInterfacesAreIgnored() {
        let rows = [
            iface("en0", in: 1_024, out: 2_048),
            iface("en1", in: 4_096, out: 8_192),
        ]
        #expect(CounterSourceSelector.ifMibLooksSanitized(ifmib: rows, iflist2: rows) == false)
    }
}

// MARK: - Interface classification and selection

@Suite("Interface selection")
struct InterfaceSelectionTests {
    @Test("Tunnels, loopback and Apple-internal interfaces are excluded from physical")
    func virtualInterfacesAreNotPhysical() {
        #expect(iface("en0", in: 0, out: 0).isPhysical)
        #expect(iface("en5", in: 0, out: 0).isPhysical)
        #expect(iface("lo0", in: 0, out: 0, flags: up | loopback).isPhysical == false)
        #expect(iface("utun8", in: 0, out: 0).isPhysical == false)
        #expect(iface("awdl0", in: 0, out: 0).isPhysical == false)
        #expect(iface("bridge0", in: 0, out: 0).isPhysical == false)
        #expect(iface("anpi0", in: 0, out: 0).isPhysical == false)
    }

    @Test("The primary policy measures exactly one interface")
    func primaryPolicySelectsOne() {
        let rows = [
            iface("en0", in: 10, out: 10),
            iface("utun8", in: 10, out: 10),
            iface("lo0", in: 10, out: 10, flags: up | loopback),
        ]
        let selected = NetworkInterfaces.select(from: rows, policy: .primary, primary: "en0")

        #expect(selected.map(\.name) == ["en0"])
    }

    @Test("With no primary interface, the selection falls back to physical ones")
    func missingPrimaryFallsBack() {
        let rows = [
            iface("en0", in: 10, out: 10),
            iface("utun8", in: 10, out: 10),
            iface("en9", in: 10, out: 10, flags: 0),   // down
        ]
        let selected = NetworkInterfaces.select(from: rows, policy: .primary, primary: nil)

        #expect(selected.map(\.name) == ["en0"])
    }

    @Test("allPhysical sums NICs but never the tunnel carrying the same bytes")
    func allPhysicalExcludesTunnels() {
        let rows = [
            iface("en0", in: 10, out: 10),
            iface("en1", in: 20, out: 20),
            iface("utun8", in: 10, out: 10),
            iface("lo0", in: 99, out: 99, flags: up | loopback),
        ]
        let selected = NetworkInterfaces.select(from: rows, policy: .allPhysical, primary: "en0")

        #expect(selected.map(\.name) == ["en0", "en1"])
    }
}

// MARK: - Public address

@Suite("Public address parsing")
struct PublicAddressTests {
    private func body(_ text: String) -> Data { Data(text.utf8) }

    @Test("A bare address of either family is accepted")
    func acceptsBareAddresses() {
        #expect(PublicAddress.parse(body("203.0.113.7")) == "203.0.113.7")
        #expect(PublicAddress.parse(body("2001:db8::1")) == "2001:db8::1")
    }

    @Test("Surrounding whitespace is tolerated")
    func trimsWhitespace() {
        #expect(PublicAddress.parse(body("  203.0.113.7\n")) == "203.0.113.7")
    }

    @Test("Bodies that are not addresses are rejected")
    func rejectsNonAddresses() {
        // A captive portal, an error page, a JSON envelope, and an empty reply.
        #expect(PublicAddress.parse(body("<html>Sign in to continue</html>")) == nil)
        #expect(PublicAddress.parse(body("Service Unavailable")) == nil)
        #expect(PublicAddress.parse(body(#"{"ip":"203.0.113.7"}"#)) == nil)
        #expect(PublicAddress.parse(body("")) == nil)
        #expect(PublicAddress.parse(body("   ")) == nil)
    }

    @Test("Malformed and shorthand address forms are rejected")
    func rejectsMalformedAddresses() {
        #expect(PublicAddress.parse(body("999.1.1.1")) == nil)
        #expect(PublicAddress.parse(body("203.0.113")) == nil)
        // inet_aton would read this as 10.0.0.1; inet_pton correctly will not.
        #expect(PublicAddress.parse(body("10.1")) == nil)
        #expect(PublicAddress.parse(body("203.0.113.7 and more")) == nil)
        #expect(PublicAddress.parse(body("2001:db8:::1")) == nil)
    }

    @Test("An oversized body is rejected before it is parsed")
    func rejectsOversizedBodies() {
        let padded = "203.0.113.7" + String(repeating: " ", count: 200)
        #expect(padded.utf8.count > PublicAddress.maximumResponseBytes)
        #expect(PublicAddress.parse(body(padded)) == nil)
    }

    @Test("Invalid UTF-8 is rejected rather than lossily decoded")
    func rejectsInvalidUTF8() {
        #expect(PublicAddress.parse(Data([0xFF, 0xFE, 0xFD])) == nil)
    }
}

// MARK: - Formatting

@Suite("Byte formatting")
struct ByteFormatTests {
    @Test("Values scale into decimal units")
    func scalesDecimally() {
        #expect(ByteFormat.scaled(0) == "0 B")
        #expect(ByteFormat.scaled(999) == "999 B")
        #expect(ByteFormat.scaled(1_000) == "1.0 KB")
        #expect(ByteFormat.scaled(1_500) == "1.5 KB")
        #expect(ByteFormat.scaled(48_000) == "48 KB")
        #expect(ByteFormat.scaled(1_200_000) == "1.2 MB")
        #expect(ByteFormat.scaled(4_700_000_000) == "4.7 GB")
    }

    @Test("Sub-byte and non-finite values degrade to zero rather than NaN")
    func handlesDegenerateInput() {
        #expect(ByteFormat.scaled(0.4) == "0 B")
        #expect(ByteFormat.scaled(.nan) == "0 B")
        #expect(ByteFormat.scaled(.infinity) == "0 B")
    }

    @Test("Rates carry a per-second suffix")
    func ratesAreSuffixed() {
        #expect(ByteFormat.rate(1_200_000) == "1.2 MB/s")
        #expect(ByteFormat.total(1_200_000) == "1.2 MB")
    }
}

// MARK: - App info

@Suite("App info")
struct AppInfoTests {
    @Test("Name and marketing version are joined for display")
    func nameAndVersion() {
        #expect(AppInfo.versionLabel(name: "Blip", shortVersion: "1.0.0") == "Blip 1.0.0")
    }

    @Test("Outside a bundle the name survives on its own")
    func missingVersionDegradesToName() {
        // `swift run` and `swift test` both have no Info.plist, so this is the
        // shape the function really sees during development, not a hypothetical.
        #expect(AppInfo.versionLabel(name: nil, shortVersion: nil) == "Blip")
        #expect(AppInfo.versionLabel(name: "Blip", shortVersion: nil) == "Blip")
    }

    @Test("Empty strings are treated as absent rather than rendered")
    func emptyFieldsAreNotRendered() {
        // A blank key must not leave a leading space or a naked version.
        #expect(AppInfo.versionLabel(name: "Blip", shortVersion: "") == "Blip")
        #expect(AppInfo.versionLabel(name: "", shortVersion: "1.0.0") == "Blip 1.0.0")
    }
}
