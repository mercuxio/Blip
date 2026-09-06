import CBlip
import Darwin

/// A single interface's cumulative byte counters, as reported by the kernel.
public struct InterfaceCounters: Sendable, Equatable, Hashable {
    public let name: String
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    public let flags: UInt32
    public let type: UInt32

    public init(name: String, bytesIn: UInt64, bytesOut: UInt64, flags: UInt32 = 0, type: UInt32 = 0) {
        self.name = name
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.flags = flags
        self.type = type
    }

    public var isUp: Bool { flags & UInt32(IFF_UP) != 0 }
    public var isLoopback: Bool { flags & UInt32(IFF_LOOPBACK) != 0 }

    /// Interfaces that carry traffic in their own right, as opposed to a view
    /// onto traffic that also crosses a physical NIC.
    ///
    /// This is the whole double-counting fix: a Tailscale/VPN `utun` carries
    /// bytes that ALSO cross `en0`, so summing every non-loopback interface
    /// reports that traffic twice. AWDL (AirDrop), bridges and the various
    /// Apple-internal interfaces have the same problem.
    public var isPhysical: Bool {
        if isLoopback { return false }
        let virtualPrefixes = [
            "utun", "ipsec", "ppp",          // VPN tunnels
            "awdl", "llw", "p2p", "nan",     // Apple wireless direct / AirDrop
            "bridge", "vmenet", "vnic",      // bridges and VM host interfaces
            "gif", "stf",                    // tunnel pseudo-interfaces
            "ap", "anpi", "pktap", "XHC",    // Apple-internal
        ]
        return !virtualPrefixes.contains { name.hasPrefix($0) }
    }
}

/// Which kernel path a set of counters came from.
public enum CounterSourceKind: String, Sendable {
    /// `net.link.generic.ifdata.<row>.general` — true 64-bit counters.
    case ifmib
    /// `NET_RT_IFLIST2` — 32-bit wrapped and 1 KiB quantized on current macOS.
    case iflist2
}

public protocol CounterSource: Sendable {
    var kind: CounterSourceKind { get }
    func read() -> [InterfaceCounters]
}

// MARK: - Implementations

public struct IfMibCounterSource: CounterSource {
    public init() {}
    public var kind: CounterSourceKind { .ifmib }
    public func read() -> [InterfaceCounters] {
        readRows { blip_read_ifmib($0, $1) }
    }
}

public struct IfList2CounterSource: CounterSource {
    public init() {}
    public var kind: CounterSourceKind { .iflist2 }
    public func read() -> [InterfaceCounters] {
        readRows { blip_read_iflist2($0, $1) }
    }
}

private func readRows(
    _ call: (UnsafeMutablePointer<BlipIfCounters>, Int32) -> Int32
) -> [InterfaceCounters] {
    let capacity = 256
    var raw = [BlipIfCounters](repeating: BlipIfCounters(), count: capacity)
    let count = raw.withUnsafeMutableBufferPointer { buffer in
        call(buffer.baseAddress!, Int32(capacity))
    }
    guard count > 0 else { return [] }
    return raw.prefix(Int(count)).map { row in
        InterfaceCounters(
            name: cString(row.name),
            bytesIn: row.ibytes,
            bytesOut: row.obytes,
            flags: row.flags,
            type: row.type
        )
    }
}

/// Converts an imported fixed-size C `char[N]` (a Swift tuple) to a String.
func cString<T>(_ value: T) -> String {
    withUnsafeBytes(of: value) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
}

// MARK: - Source selection

public enum CounterSourceSelector {
    /// Picks the counter source to run with, cross-checking at launch.
    ///
    /// `ifmib` is correct today, but the behaviour it relies on is arguably an
    /// oversight on Apple's part — the same sanitization applied to the rtsock
    /// path could be extended to it in any OS update. Rather than silently
    /// start reporting a fraction of reality, detect that and fall back to the
    /// wrapping-delta reader, which is lossy but not wrong by three orders of
    /// magnitude.
    public static func choose() -> (source: any CounterSource, degraded: Bool) {
        let ifmib = IfMibCounterSource()
        let iflist2 = IfList2CounterSource()

        let mibRows = ifmib.read()
        guard !mibRows.isEmpty else { return (iflist2, true) }

        if ifMibLooksSanitized(ifmib: mibRows, iflist2: iflist2.read()) {
            return (iflist2, true)
        }
        return (ifmib, false)
    }

    /// True when ifmib has started returning the same truncated, 1 KiB-floored
    /// values as the rtsock path.
    ///
    /// Pure so it can be tested against captured fixtures rather than a live
    /// kernel. Deliberately conservative: it demands agreement across at least
    /// two busy interfaces, so a coincidental match cannot demote a healthy
    /// source (odds of two independent counters both landing on a 1 KiB
    /// boundary are about one in a million).
    public static func ifMibLooksSanitized(
        ifmib: [InterfaceCounters],
        iflist2: [InterfaceCounters]
    ) -> Bool {
        let listByName = Dictionary(iflist2.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var comparable = 0

        for row in ifmib {
            // Only interfaces with real traffic carry signal.
            guard row.bytesIn > 1 << 20, let peer = listByName[row.name] else { continue }
            comparable += 1
            let quantized = row.bytesIn % 1024 == 0 && row.bytesOut % 1024 == 0
            let identical = row.bytesIn == peer.bytesIn && row.bytesOut == peer.bytesOut
            if !(quantized && identical) { return false }
        }

        return comparable >= 2
    }
}
