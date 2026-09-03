import CInOut
import Darwin

public struct Connection: Sendable, Hashable, Identifiable {
    public enum NetProtocol: String, Sendable {
        case tcp = "TCP"
        case udp = "UDP"
    }

    /// TCP states from `netinet/tcp_fsm.h`.
    public enum State: UInt8, Sendable {
        case closed = 0, listen, synSent, synReceived, established
        case closeWait, finWait1, closing, lastAck, finWait2, timeWait

        public var label: String {
            switch self {
            case .closed: "Closed"
            case .listen: "Listening"
            case .synSent, .synReceived: "Connecting"
            case .established: "Established"
            case .closeWait, .finWait1, .closing, .lastAck, .finWait2: "Closing"
            case .timeWait: "Wait"
            }
        }
    }

    public let pid: Int32
    public let processName: String
    public let localAddress: String
    public let localPort: UInt16
    public let remoteAddress: String
    public let remotePort: UInt16
    public let isIPv6: Bool
    public let netProtocol: NetProtocol
    public let state: State

    public init(
        pid: Int32, processName: String,
        localAddress: String, localPort: UInt16,
        remoteAddress: String, remotePort: UInt16,
        isIPv6: Bool, netProtocol: NetProtocol, state: State
    ) {
        self.pid = pid
        self.processName = processName
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.isIPv6 = isIPv6
        self.netProtocol = netProtocol
        self.state = state
    }

    public var id: String {
        "\(pid).\(netProtocol.rawValue).\(localAddress):\(localPort)>\(remoteAddress):\(remotePort)"
    }

    /// A socket bound locally with no peer — a server waiting for inbound
    /// connections rather than an active conversation.
    public var isListening: Bool {
        state == .listen || remotePort == 0
    }

    public var remoteDescription: String {
        guard !isListening else { return "listening :\(localPort)" }
        return isIPv6 ? "[\(remoteAddress)]:\(remotePort)" : "\(remoteAddress):\(remotePort)"
    }
}

public protocol ConnectionSource: Sendable {
    func read() -> [Connection]
}

/// Enumerates sockets via `libproc`, with no subprocess.
///
/// The alternative — shelling out to `lsof` or `nettop` — buys nothing here and
/// costs real reliability: a hung child process blocks the reader forever
/// (a failure mode the Stats app shipped for years), and it drags in a PATH
/// dependency and a text format that changes between OS releases.
public struct LibprocConnectionSource: ConnectionSource {
    public init() {}

    public func read() -> [Connection] {
        let capacity = 4096
        var raw = [InOutConnection](repeating: InOutConnection(), count: capacity)
        let count = raw.withUnsafeMutableBufferPointer { buffer in
            inout_read_connections(buffer.baseAddress!, Int32(capacity))
        }
        guard count > 0 else { return [] }

        return raw.prefix(Int(count)).map { row in
            Connection(
                pid: row.pid,
                processName: cString(row.process),
                localAddress: cString(row.local_addr),
                localPort: row.local_port,
                remoteAddress: cString(row.remote_addr),
                remotePort: row.remote_port,
                isIPv6: row.family == 6,
                netProtocol: row.proto == UInt8(IPPROTO_TCP) ? .tcp : .udp,
                state: Connection.State(rawValue: row.state) ?? .closed
            )
        }
    }
}

/// Orders connections for display: active conversations first, then grouped by
/// process so one app's sockets read as a block.
public func sortedForDisplay(_ connections: [Connection]) -> [Connection] {
    connections.sorted { a, b in
        if a.isListening != b.isListening { return !a.isListening }
        if a.processName.caseInsensitiveCompare(b.processName) != .orderedSame {
            return a.processName.caseInsensitiveCompare(b.processName) == .orderedAscending
        }
        if a.remoteAddress != b.remoteAddress { return a.remoteAddress < b.remoteAddress }
        return a.remotePort < b.remotePort
    }
}
