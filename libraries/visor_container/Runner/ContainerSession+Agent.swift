// The container runner's agent (VisorServer's ContainerAgent) as the
// engine's wrapper session (ContainerSession): agent-wrapper told who it
// is, its job (the conversation it resumes and its folder: no repositories,
// which its agent clones itself), its token, and its harness's environment,
// as a runner tells it, with no dispatcher to report to (Visor drives it,
// and nothing claims it).

import VisorContainerCore
import VisorServer

extension ContainerSession {
    public init(agent: ContainerAgent) {
        self.init(id: agent.agent, dispatcherURL: ContainerEngine.driverURL, title: agent.title, harness: agent.harness, model: agent.model,
                  effort: agent.effort, workingDirectory: agent.workingDirectory, resumeSessionID: agent.resumeSessionID,
                  skipPermissions: agent.skipPermissions, token: agent.token, environment: agent.environment)
    }
}
