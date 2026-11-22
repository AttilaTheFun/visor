import Foundation

public struct ToolOutcome: Sendable, Equatable {
    public let text: String
    public let isError: Bool
    /// The repository, for the log ("-" when none was named).
    public let repo: String
    /// The log's word for it: ok, or the error's line.
    public let logOutcome: String
}
