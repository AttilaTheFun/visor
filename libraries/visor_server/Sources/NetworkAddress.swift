/// One of this computer's addresses, and which network path it is: the
/// LAN (a home or office network), or a VPN (a tailnet, a company's VPN:
/// the interfaces such networks make, or the 100.64.0.0/10 range they
/// use). Each path is let in or not by the settings.
public struct NetworkAddress: Equatable, Sendable {
    public enum Kind: String, Sendable { case lan, vpn }

    public var address: String
    /// The interface it is on, when the system says ("en0", "utun4").
    public var interface: String
    public var kind: Kind

    public init(address: String, interface: String = "") {
        self.address = address
        self.interface = interface
        kind = Self.kind(of: address, on: interface)
    }

    /// A VPN by its interface's name where there is one, else by its range.
    public static func kind(of address: String, on interface: String) -> Kind {
        let name = interface.lowercased()
        for prefix in ["utun", "tun", "tap", "wg", "ppp", "ipsec", "tailscale", "ts"] where name.hasPrefix(prefix) {
            return .vpn
        }
        return isCarrierGradeNAT(address) ? .vpn : .lan
    }

    /// 100.64.0.0/10, the range tailnets and other overlay networks use.
    static func isCarrierGradeNAT(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts[0] == 100 else { return false }
        return (64...127).contains(parts[1])
    }

    /// Loopback: this computer's own road, always open.
    public static func isLoopback(_ address: String) -> Bool {
        address == "127.0.0.1" || address == "::1" || address.hasPrefix("127.")
    }
}
