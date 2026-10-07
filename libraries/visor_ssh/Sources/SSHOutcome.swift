import Synchronization

/// What one hop's handshake found, written from the event loop and read
/// once it is over: the host key seen, and what was refused.
final class SSHOutcome: Sendable {
    private struct State { var seen: String?; var failure: SSHError? }
    private let expected: String?
    private let state = Mutex(State())

    init(expected: String?) { self.expected = expected }

    /// Takes the host key seen: whether it is the expected one (or none was).
    func take(_ key: String) -> Bool {
        state.withLock { state in
            state.seen = key
            if let expected, expected != key { state.failure = .hostKeyChanged; return false }
            return true
        }
    }

    func refuseKey() { state.withLock { $0.failure = .keyRefused } }
    var hostKey: String? { state.withLock { $0.seen } }
    var failure: SSHError? { state.withLock { $0.failure } }
}
