import Foundation

/// Why listening could not start.
public enum ListeningError: LocalizedError, Equatable {
    /// The system cannot serve TLS itself: a front of your own does.
    case tlsUnavailable
    /// The system has no Unix domain sockets: SSH clients reach the port
    /// instead, with the password.
    case unixUnavailable

    public var errorDescription: String? {
        switch self {
        case .tlsUnavailable: "TLS is not served by the server here: put a front of your own (a reverse proxy) in front of it."
        case .unixUnavailable: "This system has no socket files: SSH clients reach the port, with the password."
        }
    }
}
