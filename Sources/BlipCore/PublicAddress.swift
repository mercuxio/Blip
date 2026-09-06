import Darwin
import Foundation

/// The address the internet sees us as.
///
/// Unlike every other number this app shows, this one cannot be read from the
/// kernel: behind NAT the machine genuinely does not know its public address,
/// so the only source of truth is a remote server reporting the source address
/// it observed. That makes the reply *untrusted input from the network*, which
/// is why the parse below is strict rather than a convenience.
public enum PublicAddress {
    /// Endpoints that echo the caller's source address as a bare string.
    ///
    /// Two single-stack hosts rather than one dual-stack host: `api.ipify.org`
    /// is reachable only over IPv4 and `api6.ipify.org` only over IPv6, so each
    /// answer is unambiguously that family's address instead of "whichever one
    /// the connection happened to pick".
    public static let ipv4Endpoint = URL(string: "https://api.ipify.org")!
    public static let ipv6Endpoint = URL(string: "https://api6.ipify.org")!

    /// Refuse to consider more than this many bytes. A well-formed reply is
    /// under 40; anything larger is a captive portal, an error page, or a
    /// hostile server, and there is no reason to inspect it further.
    public static let maximumResponseBytes = 128

    /// The longest possible textual IPv6 address, `INET6_ADDRSTRLEN` less its
    /// trailing NUL.
    private static let maximumAddressLength = 45

    /// Validates a raw response body and returns the address it contains.
    ///
    /// Returns `nil` for anything that is not a bare IP literal — an HTML error
    /// page, a captive-portal redirect, a JSON envelope, or trailing padding.
    /// `inet_pton` is the arbiter rather than a regular expression, because it
    /// is the same parser the network stack itself uses: "valid" here therefore
    /// means valid everywhere else in the system, including the shorthand forms
    /// (`10.1`, `999.1.1.1`) that `inet_pton` correctly rejects and the older
    /// `inet_aton` would have waved through.
    public static func parse(_ data: Data) -> String? {
        guard data.count <= maximumResponseBytes,
              let raw = String(data: data, encoding: .utf8)
        else { return nil }

        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximumAddressLength else { return nil }

        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return text }

        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 { return text }

        return nil
    }
}
