/// The device's own networks, as the host knows them: whether an address
/// is on a network this device is on right now (the LAN at home, say),
/// and a word when the networks change (Wi-Fi joined or left, a VPN up
/// or down), so a client can pick the path that fits where it is and
/// change it the moment that changes. A host without it (the web)
/// provides none: paths are tried in the order they are kept.
@MainActor
public protocol VisorNetworkService: AnyObject {
    /// Whether `host` (an IPv4 address) is on one of this device's own
    /// networks, by the address and mask of each interface.
    func isOnLocalNetwork(_ host: String) -> Bool
    /// Whether this device has an address on an overlay network (a
    /// tailnet, 100.64.0.0/10) right now.
    var hasVPN: Bool { get }
    /// Called, on the main actor, when the device's networks change.
    var onChange: (@MainActor () -> Void)? { get set }
}
