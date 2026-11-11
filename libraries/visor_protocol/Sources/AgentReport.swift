// What a wrapped agent reports of its task to the runner that started it,
// over the runner's MCP (agent → wrapper → MultiPass → runner), which the
// runner passes on to the server (docs/runners.md, "Shireworks' agent
// runner and agent jobs": report_progress, report_complete, report_blocked).
// The session is MultiPass's word of the caller, never the agent's.

import Foundation

/// A wrapped agent's word of how its task goes.
public struct AgentReport: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// Still going (report_progress).
        case progress
        /// Nothing left for the agent (report_complete).
        case complete
        /// It can't go on (report_blocked), or the runner stopped it.
        case blocked
    }

    /// Why a blocked agent can't go on.
    public enum Reason: String, Codable, Hashable, Sendable {
        /// Its pull request touches code-owned files.
        case codeReview = "code_review"
        /// It needs Logan's answer: `detail` is the question.
        case question
        /// CI or tooling it can't fix.
        case failure
        /// The runner's own: no report and no output for too long.
        case stuck
    }

    public var session: String
    public var kind: Kind
    /// A sentence or two: what it's doing, what it did, or why it's blocked.
    public var summary: String
    /// Free text for a progress report's stage (`tests`, `review`).
    public var step: String?
    /// The pull request, when there is one.
    public var pullRequest: String?
    /// For a complete report: whether it merged its own pull request.
    public var merged: Bool?
    /// For a blocked report.
    public var reason: Reason?
    public var at: Date

    public init(session: String, kind: Kind, summary: String, step: String? = nil, pullRequest: String? = nil, merged: Bool? = nil,
                reason: Reason? = nil, at: Date) {
        self.session = session
        self.kind = kind
        self.summary = summary
        self.step = step
        self.pullRequest = pullRequest
        self.merged = merged
        self.reason = reason
        self.at = at
    }
}
