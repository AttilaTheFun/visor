// The device's networks, from the system: the interfaces' addresses and
// masks (getifaddrs), and the Network framework's word when the path
// changes.

import Foundation
import Network

@MainActor
public final class NativeVisorNetworkService: VisorNetworkService {
    private let monitor = NWPathMonitor()
    public var onChange: (@MainActor () -> Void)?

    public init() {
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.onChange?() }
        }
        monitor.start(queue: .main)
    }

    public func isOnLocalNetwork(_ host: String) -> Bool {
        guard let target = Self.ipv4(host) else { return false }
        return Self.interfaces().contains { address, mask in (address & mask) == (target & mask) && mask != 0 }
    }

    public var hasVPN: Bool {
        Self.interfaces().contains { address, _ in (address & 0xFFC0_0000) == 0x6440_0000 }
    }

    /// Each IPv4 interface's address and mask, loopback left out.
    private static func interfaces() -> [(UInt32, UInt32)] {
        var result: [(UInt32, UInt32)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), let netmask = entry.ifa_netmask else { continue }
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if value >> 24 == 127 { continue }
            result.append((value, mask))
        }
        return result
    }

    /// An IPv4 address as a number; nil for anything else.
    static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }
}
