// Who knows a driven agent, for the driver (VisorDriver's DriverService):
// the session it carries on, whether the token a call shows is its own, the
// conversation it was moved with, a fresh token for its stream, and whether
// it runs in a container (which MCP servers its session gets). Two hold
// agents: the dispatcher's JobQueue (a runner's agent, which claimed a job;
// deprecated) and the container runner (an agent Visor started itself in
// its Sessions container, which claims nothing).

import Foundation

@MainActor
package protocol DrivenAgentDirectory: AnyObject, Sendable {
    /// Whether it holds `agent`.
    func holds(_ agent: String) -> Bool
    /// Whether a call for `agent` that shows `bearers` is the agent's.
    /// `withinGrace`: a runner's Renew or Release (the dispatcher's alone).
    func access(_ agent: String, bearers: [String], withinGrace: Bool, now: Date) -> DrivenAgentAccess
    /// The session `agent` carries on.
    func session(of agent: String) -> String
    /// The conversation `agent`'s session was moved with, and where it was
    /// here: what the driver's Conversation sends it.
    func conversation(of agent: String) -> (resume: String, cwd: String)?
    /// A new token for `agent`, as its session.
    func token(for agent: String) -> String
    /// When `token` ends, if it is one of this server's.
    func expiry(of token: String) -> Date?
    /// How long before its token ends an agent's stream is sent a fresh one.
    var tokenRefreshLead: TimeInterval { get }
    /// Whether `agent` runs in a container: its session gets Visor's own
    /// MCP tools alone from the driver, never the servers this computer
    /// passes on (a Sessions container's agent reaches those from
    /// agent-proxy's pass-through, with a token of its own).
    func runsInContainer(_ agent: String) -> Bool
}
