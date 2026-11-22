import Foundation

/// What a tool says when it does not do what it was asked: one line each.
public enum ToolError: Error, Sendable, Equatable {
    /// The arguments are wrong (missing, mistyped, malformed).
    case invalid(String)
    /// The arguments are fine, but the rules forbid it.
    case refused(String)
    /// It was tried and did not work (GitHub, git, the network).
    case failed(String)

    public var text: String {
        switch self {
        case .invalid(let message): "Invalid: \(message)"
        case .refused(let message): "Refused: \(message)"
        case .failed(let message): "Failed: \(message)"
        }
    }

    /// What the call log keeps of it.
    public var outcome: String {
        switch self {
        case .invalid(let message): "invalid: \(message)"
        case .refused(let message): "refused: \(message)"
        case .failed(let message): "failed: \(message)"
        }
    }
}
