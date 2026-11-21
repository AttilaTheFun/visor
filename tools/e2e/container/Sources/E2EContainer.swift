// The engine as //tools/e2e/container's own Visor server reaches it (its
// SessionsContainer, as the server agent's MacSessionsContainer is): the
// sessions placed in it have their agent-wrappers started in it, with the
// stand-in claude (AGENT_WRAPPER_CLAUDE), sharing only the run's scratch
// folder on Sessions, so their folders and Claude folder are in it.

import Foundation
import VisorContainerCore
import VisorContainerRunner
import VisorProtocol
import VisorServer

final class E2EContainer: SessionsContainer {
    let engine: ContainerEngine
    /// The run's scratch folder on Sessions.
    let scratch: String
    /// The stand-in claude, on it.
    let claude: String

    init(engine: ContainerEngine, scratch: String, claude: String) {
        self.engine = engine
        self.scratch = scratch
        self.claude = claude
    }

    func status() async -> ContainerStatus { await engine.status() }
    func start() async -> ContainerStatus { await engine.start() }
    func stop() async -> ContainerStatus { await engine.stop() }
    func restart() async -> ContainerStatus { await engine.restart() }
    var sharedFolders: [String] { [scratch] }

    func startAgent(_ agent: ContainerAgent) async throws -> any ContainerAgentRun {
        var session = ContainerSession(agent: agent)
        session.claudeProgram = claude
        return EngineAgentRun(execution: try await engine.startWrapper(session: session))
    }

    @MainActor func settingsChanged(_ settings: ServerSettings) {}
    func loopbackPortIsFree(_ port: Int) -> Bool { LoopbackPort.isFree(port) }
}
