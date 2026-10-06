import Foundation
import VisorServer

/// This computer's IPv4 addresses, loopback left out, from the system's
/// list of interfaces (getifaddrs).
public enum POSIXAddresses {
    public static func all() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, Int32(address.pointee.sa_family) == AF_INET else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if text != "127.0.0.1" { result.append(text) }
            }
        }
        // A VPN's address first: it reaches the computer from anywhere.
        return result.sorted { a, b in a.hasPrefix("100.") && !b.hasPrefix("100.") }
    }
}
