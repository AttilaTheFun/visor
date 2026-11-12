// Sessions whose agents run under agent_protocol's wrapper, elsewhere or
// on this computer, with this server as their driver (VisorDriver): their
// process is the wrapper's stream, their rows come over it, and they are
// never started here. Taken in when the wrapper says who it is, and again
// when it dials after a drop or a restart of either side.

import Foundation
import VisorAgent
import VisorProtocol

extension VisorServer {
    /// The session for a wrapper that said hello: the one it had (its
    /// process now `process`), or a new one.
    @discardableResult
    package func takeDriven(_ info: SessionInfo, process: AgentProcess) -> SessionRecord {
        if let record = session(info.id) {
            if record.process !== process {
                record.stopListening()
                record.process = process
            }
            record.driven = true
            if !record.isBound { bind(record) }
            if record.info.archived { record.setArchived(false) }
            setAgentState(record, .running)
            saveArchiveNow()
            broadcastSessions()
            return record
        }
        let record = SessionRecord(info: info, process: process)
        record.driven = true
        sessions.append(record)
        bind(record)
        record.info.agentState = .running
        Self.log("driven session: \(info.title) (\(info.agent.title)) in \(info.cwd)")
        saveArchiveNow()
        broadcastSessions()
        return record
    }

    /// A job for a runner, from a client (an envelope as for a session: its
    /// agent, title, folder, model, and its first prompt as `text`).
    func restQueueJob(_ call: RESTCall) -> HTTPResponse {
        guard let jobs else { return HTTPResponse(404, Envelope.error("No runners take jobs here.").encoded()) }
        switch jobs.queueStart(call.body) {
        case .success(let id):
            var e = Envelope(type: "job")
            e.id = id
            return .json(e.encoded())
        case .failure(let refusal):
            return HTTPResponse(400, Envelope.error(refusal.reason).encoded())
        }
    }
}
