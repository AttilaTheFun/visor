import Foundation

/// Where an agent's GitHub token comes from. In Visor (0.66) it is
/// agent-token, run as gh_mcp ran it (AgentTokenCommand), the command that
/// holds the GitHub Apps' keys. The seam for what comes next: a source that
/// mints installation tokens in-process, from App keys kept with Visor's
/// secrets (a JWT signed with the App's key, then `POST
/// /app/installations/{id}/access_tokens`), takes its place here and
/// nothing else changes; TokenCache keeps what either gives.
public protocol TokenSource: Sendable {
    /// The agent's GitHub App's installation token for `owner`'s
    /// repositories.
    func token(agent: String, owner: String) async throws -> String
}
