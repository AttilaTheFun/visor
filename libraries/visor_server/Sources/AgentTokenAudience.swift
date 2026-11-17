// Whom an agent's token is for (its JWT's `aud`): a native session's agent,
// or an agent run under agent_protocol's wrapper on a runner. A token for
// the one is never taken as the other.

/// A JWT's `aud`, as this server mints and asks it.
package enum AgentTokenAudience: String, Codable, Sendable {
    /// A native session's agent (its MCP bridge and permission asks).
    case session = "visor.session"
    /// A runner's agent, through its wrapper (agent_protocol's Job.token).
    case runnerAgent = "visor.runner-agent"

    /// What a token for it may do.
    package var scope: [AgentTokenScope] {
        switch self {
        case .session: [.messages, .approvals, .mcp]
        case .runnerAgent: [.messages, .approvals, .mcp, .job]
        }
    }
}
