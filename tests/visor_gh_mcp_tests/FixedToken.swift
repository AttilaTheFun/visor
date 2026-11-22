@testable import VisorGHMCP

/// A token for every agent and owner, never asked of agent-token.
struct FixedToken: TokenSource {
    func token(agent: String, owner: String) async throws -> String { "ghs_testtoken\(agent)\(owner)" }
}
