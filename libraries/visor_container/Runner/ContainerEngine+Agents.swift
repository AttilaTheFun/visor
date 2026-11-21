// The engine as the container runner reaches it (VisorServer's
// SessionsContainer): a session's agent started in it (its agent-wrapper,
// ContainerEngine.startWrapper) and held as a ContainerAgentRun, and the
// folders it shares at the same path, which a session moving in keeps.

import VisorContainerCore
import VisorServer

extension ContainerEngine {
    /// `agent`'s agent-wrapper started in the container.
    public func startAgent(_ agent: ContainerAgent) async throws -> any ContainerAgentRun {
        EngineAgentRun(execution: try await startWrapper(session: ContainerSession(agent: agent)))
    }

    /// Sessions, then the checkouts' folder when one is set outside it.
    public nonisolated func sharedFolders(_ configuration: ContainerEngineConfiguration) -> [String] {
        let sessions = context.sessions
        guard let checkouts = configuration.checkouts, checkouts != sessions, !checkouts.hasPrefix(sessions + "/") else { return [sessions] }
        return [sessions, checkouts]
    }
}
