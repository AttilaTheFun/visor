// What a wrapped agent reports of its task to the runner that started it,
// over the runner's MCP (agent → wrapper → MultiPass → runner), and the
// runner passes on to the server (docs/runners.md, "Shireworks' agent
// runner and agent jobs"). The tools' exact shapes are Shireworks' to agree.

import Foundation

/// A wrapped agent's word of how its task goes.
public struct AgentReport: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// Still going: what it is doing.
        case progress
        /// Done: its pull request merged, or the task otherwise finished.
        case complete
        /// It can't go on: why (code review, a question, a failure), or the
        /// runner stopped it for saying nothing too long.
        case blocked
    }

    public var session: String
    public var kind: Kind
    /// A line saying what, or why.
    public var text: String
    /// The pull request, when there is one.
    public var pullRequest: String?
    public var at: Date

    public init(session: String, kind: Kind, text: String, pullRequest: String? = nil, at: Date) {
        self.session = session
        self.kind = kind
        self.text = text
        self.pullRequest = pullRequest
        self.at = at
    }
}
