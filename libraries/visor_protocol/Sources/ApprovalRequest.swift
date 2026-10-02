#if canImport(Foundation)
import Foundation
#endif

/// A tool call waiting for the user's Allow or Deny (manual mode).
public struct ApprovalRequest: Codable, Hashable, Sendable {
    public var id: String
    /// The tool ("Bash", "Edit"…).
    public var tool: String
    /// One line of what it wants to do.
    public var summary: String

    public init(id: String, tool: String, summary: String) {
        self.id = id
        self.tool = tool
        self.summary = summary
    }
}
