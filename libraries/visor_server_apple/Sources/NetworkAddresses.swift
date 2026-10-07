import Foundation

/// This Mac's addresses on its networks.
public enum NetworkAddresses {
    /// Its IPv4 addresses, loopback left out: a VPN's (the 100.64.0.0/10
    /// range such networks use) first, then the LAN's.
    public static func all() -> [(name: String, address: String)] {
        var result: [(String, String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if text == "127.0.0.1" || text.hasPrefix("169.254.") { continue }
                result.append((String(cString: entry.ifa_name), text))
            }
        }
        // A VPN's address first: it reaches the Mac from anywhere.
        return result.sorted { a, b in a.1.hasPrefix("100.") && !b.1.hasPrefix("100.") }
    }
}
