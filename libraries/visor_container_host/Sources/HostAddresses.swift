import Foundation

/// This computer's IPv4 addresses a client may reach a container server's
/// port at: on the LAN (a private address) and on a VPN (a tailnet's
/// 100.64.0.0/10), leaving out loopback and the bridges to its containers
/// and VMs, which are the same on every Mac.
public enum HostAddresses {
    public struct Address: Equatable, Sendable {
        public var interface: String
        public var address: String
    }

    public static func all() -> [Address] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var found: [Address] = []
        for entry in sequence(first: first, next: { $0?.pointee.ifa_next }) {
            guard let entry, let address = entry.pointee.ifa_addr, Int32(address.pointee.sa_family) == AF_INET else { continue }
            var text = [CChar](repeating: 0, count: 64)
            var inet = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard inet_ntop(AF_INET, &inet, &text, socklen_t(text.count)) != nil else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let value = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            found.append(Address(interface: name, address: value))
        }
        return found
    }

    static func octets(_ address: String) -> [Int] { address.split(separator: ".").compactMap { Int($0) } }

    static func isBridge(_ address: Address) -> Bool {
        address.interface.hasPrefix("bridge") || address.interface.hasPrefix("vmnet")
    }

    public static func isVPN(_ address: String) -> Bool {
        let o = octets(address)
        return o.count == 4 && o[0] == 100 && (64...127).contains(o[1])
    }

    public static func isLAN(_ address: String) -> Bool {
        let o = octets(address)
        guard o.count == 4 else { return false }
        return o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168)
    }

    /// The address a container server's codes lead with, by its `listen`:
    /// the LAN's where it is open to the LAN, else a VPN's, else loopback.
    public static func clientHost(lan: Bool, vpn: Bool, from addresses: [Address] = all()) -> String {
        let usable = addresses.filter { !isBridge($0) }
        if lan, let found = usable.first(where: { isLAN($0.address) }) { return found.address }
        if vpn, let found = usable.first(where: { isVPN($0.address) }) { return found.address }
        return "127.0.0.1"
    }
}
