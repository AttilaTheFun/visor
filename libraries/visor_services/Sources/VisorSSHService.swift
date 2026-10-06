/// SSH, as the host provides it: a connection to a computer as a user,
/// authenticated by this device's own key, through jump hosts if need be,
/// through which a port on the computer's loopback is reached from a
/// port here. A host without SSH (the web, for now Android) provides
/// none, and an SSH address cannot be used there. The client lives on
/// the main actor; so does this.
@MainActor
public protocol VisorSSHService: AnyObject {
    /// This device's key, made once and kept: its public half as a line
    /// for the computer's `authorized_keys`.
    func publicKey() -> String
    /// Connects along `route` — each hop reached through the one before,
    /// the last being the computer — with the device's key at each.
    /// `hostKeys` are the hops' keys as last seen, by position (nil the
    /// first time): a different one is refused
    /// (`VisorSSHError.hostKeyChanged`), as the connection would be with
    /// someone else.
    func connect(_ route: [VisorSSHHop], hostKeys: [String?]) async throws -> any VisorSSHSession
}

/// One SSH connection, to the last hop of its route.
@MainActor
public protocol VisorSSHSession: AnyObject {
    /// Each hop's host key, as a line to keep and compare next time.
    var hostKeys: [String] { get }
    /// Reaches `port` on the computer's loopback through a port here, on
    /// 127.0.0.1: the port, for as long as the session is open.
    func forward(toPort port: Int) async throws -> Int
    func close()
}

/// What SSH refuses.
public enum VisorSSHError: Error, Equatable, Sendable {
    /// The computer was not reached: no answer, no SSH there.
    case unreachable(String)
    /// A computer's key is not the one seen before.
    case hostKeyChanged
    /// A computer did not take this device's key.
    case keyRefused
}
