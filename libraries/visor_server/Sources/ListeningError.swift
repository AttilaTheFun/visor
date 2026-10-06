import Foundation

/// Why listening could not start.
public enum ListeningError: LocalizedError, Equatable {
    /// The system cannot serve TLS itself: a front of your own does.
    case tlsUnavailable

    public var errorDescription: String? {
        switch self {
        case .tlsUnavailable: "TLS is not served by the server here: put a front of your own (a reverse proxy) in front of it."
        }
    }
}
