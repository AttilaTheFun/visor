// Whether a job's agent runs in a container: what decides which MCP
// servers its session gets. Logan (2026-11-16): a session in a container
// gets Visor's own MCP (through its wrapper) and Shireworks' (from its
// container), never the MCP servers this computer passes on to its native
// sessions. A session on Visor's own native runner runs on this computer
// as any native session does, and keeps them.

import AgentProtocol
import Foundation

extension JobQueue {
    /// The kind of runner that runs no container.
    static let native = "native"

    /// Whether `agent`'s job runs in a container: it asks for a container
    /// runner (`runs-on:container`), or, asking for no kind, the runner
    /// that claimed it said `container` among its capabilities. A job that
    /// asks for a native runner (`runs-on:native`), or was claimed by one
    /// (`native`, not `container`), doesn't. Not known (claimed before this
    /// server's restart, by a runner that said neither): taken to, so a
    /// container's agent never gets this computer's servers by mistake.
    func runsInContainer(_ agent: String) -> Bool {
        let id = Self.key(agent)
        let job = claimed[id]?.job ?? waiting.first { Self.key($0.agent.uuid) == id }
        let kinds = job?.labels.filter { $0.hasPrefix(Self.runsOn) }.map { String($0.dropFirst(Self.runsOn.count)) } ?? []
        if kinds.contains(Self.container) { return true }
        if kinds.contains(Self.native) { return false }
        guard let capabilities = claimCapabilities[id] else { return true }
        return capabilities.contains(Self.container) || !capabilities.contains(Self.native)
    }
}
