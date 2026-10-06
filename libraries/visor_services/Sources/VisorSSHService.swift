/// SSH, as the host provides it: a connection to a computer as a user,
/// authenticated by this device's own key, through which a port on the
/// computer's loopback is reached from a port here. A host without SSH
/// (the web, for now Android) provides none, and the SSH provider is not
/// offered there. The client lives on the main actor; so does this.
@MainActor
public protocol VisorSSHService: AnyObject {
    /// This device's key, made once and kept: its public half as a line
    /// for the computer's `authorized_keys`.
    func publicKey() -> String
    /// Connects to `host`, port `port`, as `user`, with the device's key.
    /// `hostKey` is the computer's key as it was last seen (nil the first
    /// time): a different one is refused (`VisorSSHError.hostKeyChanged`),
    /// as the connection would be with someone else.
    func connect(user: String, host: String, port: Int, hostKey: String?) async throws -> any VisorSSHSession
}

/// One SSH connection.
@MainActor
public protocol VisorSSHSession: AnyObject {
    /// The computer's host key, as a line to keep and compare next time.
    var hostKey: String { get }
    /// Reaches `port` on the computer's loopback through a port here, on
    /// 127.0.0.1: the port, for as long as the session is open.
    func forward(toPort port: Int) async throws -> Int
    func close()
}

/// What SSH refuses.
public enum VisorSSHError: Error, Equatable, Sendable {
    /// The computer was not reached: no answer, no SSH there.
    case unreachable(String)
    /// The computer's key is not the one seen before.
    case hostKeyChanged
    /// The computer did not take this device's key.
    case keyRefused
}
