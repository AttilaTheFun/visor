// A driven session's process before there is a driver to reach its
// runner's agent (VisorDriver gives it its DrivenProcess when it starts):
// it starts nothing on this computer, and says why when it is asked to. A
// driven session only comes back here through moveBack (visor#424: one
// loaded with a native process became this computer's on its next message).

import Foundation
import VisorAgent
import VisorProtocol

@MainActor
final class AwaitingDriverProcess: AgentProcess {
    let events: AsyncStream<AgentEvent>
    var skipPermissions = false
    var model: String?
    var effort: String?
    var approvalEnvironment: [String: String] = [:]
    var resumeID: String? { nil }
    var resumeCommand: String? { nil }
    var processID: Int32? { nil }

    init() {
        (events, _) = AsyncStream.makeStream()
    }

    func send(_ text: String) throws { throw AwaitingDriverProcess.NoDriver() }

    func start() throws { throw AwaitingDriverProcess.NoDriver() }

    func interrupt() {}

    func stop() {}

    func end(within deadline: Duration) async {}

    /// Why nothing was sent or started.
    struct NoDriver: LocalizedError {
        var errorDescription: String? {
            "This session's agent runs on a runner, and this server has no agent_protocol driver to reach it: nothing was started here."
        }
    }
}
