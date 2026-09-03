import Darwin
import Foundation
import SystemConfiguration

/// Which interfaces the menu bar total covers.
public enum InterfacePolicy: String, Sendable, CaseIterable, Codable {
    /// Whatever the OS currently routes traffic through. The default: it is
    /// what "my network connection" means to a person, and it cannot
    /// double-count.
    case primary
    /// Every physical interface, summed. Correct when genuinely using two NICs
    /// at once; still excludes tunnels and bridges so VPN traffic is not
    /// counted on both the tunnel and the NIC underneath it.
    case allPhysical

    public var label: String {
        switch self {
        case .primary: "Primary interface"
        case .allPhysical: "All physical interfaces"
        }
    }
}

/// Holds one long-lived `SCDynamicStore` session.
///
/// Creating a session is the expensive half of a lookup — it opens a connection
/// to `configd` — while the *values* are still fetched live on every
/// `SCDynamicStoreCopyValue`, so caching the handle costs no freshness. At the
/// 1 Hz poll rate the old create-per-call also woke another process 60 times a
/// minute, a battery cost that never appeared in our own CPU number.
///
/// `@unchecked Sendable` with an explicit lock: `SCDynamicStore` carries no
/// documented thread-safety guarantee, so access is serialised rather than
/// assumed safe.
private final class DynamicStoreBox: @unchecked Sendable {
    private let lock = NSLock()
    private var store: SCDynamicStore?

    func withStore<T>(_ body: (SCDynamicStore) -> T?) -> T? {
        lock.lock()
        defer { lock.unlock() }
        if store == nil {
            store = SCDynamicStoreCreate(nil, "InOut" as CFString, nil, nil)
        }
        guard let store else { return nil }
        return body(store)
    }
}

private let dynamicStore = DynamicStoreBox()

public enum NetworkInterfaces {
    /// The interface the OS is currently routing through, e.g. `en0`.
    public static func primaryName() -> String? {
        dynamicStore.withStore { store in
            for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
                if let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                   let name = dict["PrimaryInterface"] as? String {
                    return name
                }
            }
            return nil
        }
    }

    /// Selects the rows the current policy should sum.
    ///
    /// Pure, so the double-counting rule can be tested against a captured
    /// interface list instead of whatever happens to be plugged in.
    public static func select(
        from counters: [InterfaceCounters],
        policy: InterfacePolicy,
        primary: String?
    ) -> [InterfaceCounters] {
        switch policy {
        case .primary:
            if let primary, let match = counters.first(where: { $0.name == primary }) {
                return [match]
            }
            // No primary interface (offline, or SCDynamicStore had nothing):
            // fall back rather than showing a frozen zero.
            return counters.filter { $0.isPhysical && $0.isUp }
        case .allPhysical:
            return counters.filter { $0.isPhysical && $0.isUp }
        }
    }

    /// IPv4/IPv6 addresses assigned to an interface.
    ///
    /// `getifaddrs` is the right tool for addresses. It is only its *byte
    /// counters* that are unusable (32-bit, and quantized) — the address
    /// information is fine.
    public static func addresses(for interfaceName: String) -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = entry.pointee.ifa_addr,
                  String(cString: entry.pointee.ifa_name) == interfaceName
            else { continue }

            let family = addr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            )
            guard status == 0 else { continue }

            // Strip the scope suffix IPv6 link-local addresses carry (%en0).
            var text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
            if !text.isEmpty, !result.contains(text) { result.append(text) }
        }
        return result
    }
}
