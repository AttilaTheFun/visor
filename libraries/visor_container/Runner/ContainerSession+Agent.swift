// The container runner's agent (VisorServer's ContainerAgent) as the
// engine's wrapper session (ContainerSession): agent-wrapper told who it
// is, its job (the conversation it resumes, its folder, its repositories),
// its token, and its harness's environment, as a runner tells it, with no
// dispatcher to report to (Visor drives it, and nothing claims it).

import VisorContainerCore
import VisorServer

extension ContainerSession {
    public init(agent: ContainerAgent) {
        self.init(id: agent.agent, dispatcherURL: ContainerEngine.driverURL, title: agent.title, harness: agent.harness, model: agent.model,
                  effort: agent.effort, workingDirectory: agent.workingDirectory, resumeSessionID: agent.resumeSessionID,
                  skipPermissions: agent.skipPermissions,
                  sources: agent.sources.map { Source(repository: $0.repository, ref: $0.ref, name: $0.name) }, token: agent.token,
                  sourcesDirectory: agent.sourcesDirectory, environment: agent.environment)
    }
}
