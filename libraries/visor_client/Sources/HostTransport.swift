import VisorProtocol
import VisorServices

/// A live channel carrying the protocol's envelopes both ways, and one-shot
/// calls to the computer's REST side. One transport per computer, driven
/// from the main actor like the connection that owns it.
@MainActor
public protocol HostTransport: AnyObject {
    /// Opens the live channel. A transport that cannot open reports
    /// `.closed` with the reason.
    func connect(_ config: HostConfig, onEvent: @escaping @MainActor (TransportEvent) -> Void)
    func send(_ text: String)
    func disconnect()
    /// One request to the REST side: the answer's body, or a throw.
    func call(_ method: String, _ path: String, body: String, config: HostConfig) async throws -> String
    /// The HTTP status behind what `call` threw, when it was one.
    func status(of error: Error) -> Int?
    /// A pause, for the reconnect backoff.
    func delay(milliseconds: Int32) async
}

public extension HostTransport {
    func status(of error: Error) -> Int? { nil }
}
