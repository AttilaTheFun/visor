// What an agent's token lets it do (its JWT's `scope`, an array): each
// call it makes asks for one.

/// One thing an agent's token may be used for.
package enum AgentTokenScope: String, Codable, Sendable {
    /// Asks of the other sessions: listing them, sending to and reading
    /// them, its inbox and outbox, a message's status.
    case messages
    /// Its permission prompts (`approval_request`, a wrapper's approvals).
    case approvals
    /// The MCP servers passed on to it (`mcp_tools`, `mcp_call`).
    case mcp
    /// A runner's agent's own job: the driver's Connect and Conversation,
    /// the dispatcher's Report and Renew, for its agent alone.
    case job
}
