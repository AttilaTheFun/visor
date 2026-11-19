// The addresses relay-client's resolver gives out (Visor's
// docs/server-proxy.md, "Containers: no network"): each name relayed gets
// one of 198.18.0.0/15 (RFC 2544's, never a real host's), and a connection
// to it is sent on as `CONNECT name:port`, so the name, not an address,
// goes to agent-proxy. The first, 198.18.0.1, is given to no name: it is the
// container's own, the source of every connection (ContainerNetwork).

import Synchronization

/// Names and the fake IPv4 addresses given them, both ways.
public final class FakeAddresses: Sendable {
    /// 198.18.0.0/15's first address, as a number.
    static let base: UInt32 = 198 << 24 | 18 << 16
    /// The container's own address, on loopback: its connections' source.
    public static let source = "198.18.0.1"

    private struct State {
        var byName: [String: UInt32] = [:]
        var byOffset: [UInt32: String] = [:]
        /// The next offset to give; past the last it goes round, and the
        /// name that had it loses it.
        var next: UInt32 = 2
    }

    private let state = Mutex(State())
    private let size: UInt32

    /// `size` addresses, from 198.18.0.2 (131,070 unless a test says).
    public init(size: UInt32 = (1 << 17) - 2) {
        self.size = max(size, 1)
    }

    /// The address `name` has, given now if it had none.
    public func address(for name: String) -> [UInt8] {
        let name = name.lowercased()
        let offset = state.withLock { state -> UInt32 in
            if let offset = state.byName[name] { return offset }
            let offset = state.next
            state.next = offset + 1 >= size + 2 ? 2 : offset + 1
            if let old = state.byOffset[offset] { state.byName[old] = nil }
            state.byName[name] = offset
            state.byOffset[offset] = name
            return offset
        }
        let value = Self.base + offset
        return [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    /// The name given `address` ("198.18.0.7"), if it was given one.
    public func name(for address: String) -> String? {
        let parts = address.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return nil }
        let value = parts[0] << 24 | parts[1] << 16 | parts[2] << 8 | parts[3]
        guard value >= Self.base else { return nil }
        let offset = value - Self.base
        return state.withLock { $0.byOffset[offset] }
    }
}
