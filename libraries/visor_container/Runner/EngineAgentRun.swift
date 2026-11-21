// A session's agent-wrapper exec'd in the container (ContainerExecution),
// as the container runner holds it: waited on, and signalled.

import VisorContainerCore
import VisorServer

public struct EngineAgentRun: ContainerAgentRun {
    public let execution: ContainerExecution

    public init(execution: ContainerExecution) {
        self.execution = execution
    }

    public func wait() async -> Int32 {
        await execution.wait()
    }

    public func signal(_ number: Int32) async {
        try? await execution.signal(number)
    }
}
