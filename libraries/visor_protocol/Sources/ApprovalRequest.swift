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
    /// What the agent asks the user (AskUserQuestion): answered, not
    /// allowed or denied. Nil for any other tool.
    public var questions: [AgentQuestion]?

    public init(id: String, tool: String, summary: String, questions: [AgentQuestion]? = nil) {
        self.id = id
        self.tool = tool
        self.summary = summary
        self.questions = questions
    }
}
