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
            // A session moved to a runner: where it works there now.
            if info.cwd != "~", !info.cwd.isEmpty, record.info.cwd != info.cwd { record.info.cwd = info.cwd }
            if !record.isBound { bind(record) }
            if record.info.archived { record.setArchived(false) }
            setAgentState(record, .running)
            handOverInbox(record)
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

    /// At the driver's start: every session a runner's agent runs, as the
    /// archive kept it, given its driven process again (the archive was
    /// read before there was a driver, and gave it one of this computer's).
    /// Its wrapper dials back and carries on; nothing starts it here.
    package func takeUpDrivenSessions() {
        guard let drivenProcess else { return }
        for record in sessions where record.driven {
            record.replaceProcess(drivenProcess(record.info))
        }
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

    /// Moves a session to a runner (Move to a runner…): its agent here is
    /// ended, the session becomes driven (its process the driver's, which
    /// waits for the runner's wrapper to dial), and a resume job is queued
    /// for a runner of `runsOn`, with the conversation to carry on and the
    /// repositories the session works in. The wrapper fetches the
    /// conversation (AgentDriver.Conversation) and clones them, then
    /// resumes; the session keeps its id. Refused for a session that is
    /// mid-turn, has no conversation, or has work not yet pushed.
    package func moveToRunner(_ id: String, runsOn: String) async -> Result<Void, AgentJobRefusal> {
        guard let jobs, let drivenProcess else { return .failure(AgentJobRefusal("No runners take jobs here.")) }
        guard let record = session(id) else { return .failure(AgentJobRefusal("No such session.")) }
        guard !record.driven else { return .failure(AgentJobRefusal("“\(record.info.title)” runs under a runner already.")) }
        guard record.info.agent == .claude else { return .failure(AgentJobRefusal("Runners carry on Claude Code sessions for now.")) }
        guard !record.info.busy else { return .failure(AgentJobRefusal("“\(record.info.title)” is working: move it once its turn has ended.")) }
        guard let resume = record.process.resumeID, !resume.isEmpty else {
            return .failure(AgentJobRefusal("“\(record.info.title)” has no conversation to carry on yet."))
        }
        let cwd = (record.info.cwd as NSString).expandingTildeInPath
        let conversation = SessionCatalog.conversationFiles(agent: .claude, id: resume, cwd: cwd).first { !$0.folder }?.url
        let projects = await ProjectSurvey.projects(cwd: cwd, conversation: conversation, home: SessionCatalog.home.path, worked: true)
        if let unpushed = projects.first(where: { $0.unshared }) {
            return .failure(AgentJobRefusal("\(unpushed.path) has work that isn't pushed: push it first, so the runner's clone has it."))
        }
        let sources = projects.compactMap { project -> AgentJobSource? in
            guard let remote = project.remote.flatMap(Self.cloneURL) else { return nil }
            return AgentJobSource(repository: remote, ref: project.branch ?? "", name: (project.path as NSString).lastPathComponent)
        }
        let move = AgentJobMove(session: record.info.id, title: record.info.title, model: record.info.model ?? "",
                                effort: record.info.effort ?? "", resume: resume, cwd: cwd, sources: sources, runsOn: runsOn)
        // The agent here goes first, then the session waits for the runner.
        let old = record.process
        await old.end(within: .seconds(5))
        record.replaceProcess(drivenProcess(record.info))
        record.driven = true
        // In a container, its permission prompts are skipped, as every
        // container session's are (the runner starts its agent so); a
        // native runner's agent keeps the session's own mode.
        if runsOn == "container" { record.setPermissions(skip: true) }
        if case .failure(let refusal) = jobs.queueResume(move) {
            Self.log("moving \(record.info.title) to a runner: \(refusal.reason)")
            return .failure(refusal)
        }
        setAgentState(record, .starting)
        Self.log("moving \(record.info.title) (\(record.info.id)) to a \(runsOn) runner, carrying on \(resume), with \(sources.count) repositories")
        saveArchiveNow()
        broadcastSessions()
        return .success(())
    }

    /// A moved session back on this computer: its runner's agent told to
    /// stop, the session native again on its conversation (`resume`) in
    /// `cwd`, with a notice saying why. What a move that fails or is given
    /// up does on its own (VisorDriver's JobQueue), and `POST
    /// /api/sessions/<id>/moveBack {resume, cwd}` for one left waiting.
    @discardableResult
    package func moveBack(_ id: String, resume: String, cwd: String, why: String) -> Result<Void, AgentJobRefusal> {
        guard let record = session(id) else { return .failure(AgentJobRefusal("No such session.")) }
        guard record.driven else { return .failure(AgentJobRefusal("“\(record.info.title)” runs on this computer already.")) }
        guard !resume.isEmpty else {
            return .failure(AgentJobRefusal("Which conversation “\(record.info.title)” carries on isn't known here: give it as `resume`."))
        }
        jobs?.forget(session: id)
        record.process.stop()
        record.driven = false
        if !cwd.isEmpty { record.info.cwd = cwd }
        // Prompts skipped only in a container: here they are asked again,
        // before its agent starts (Claude takes the mode at launch).
        record.setPermissions(skip: false)
        record.replaceProcess(makeProcess(record.info, resume: resume))
        record.notice = "Back on this computer: \(why)"
        Self.log("moved \(record.info.title) (\(id)) back to this computer, carrying on \(resume): \(why)")
        launchAgent(record)
        release(record)
        saveArchiveNow()
        broadcastSessions()
        return .success(())
    }

    /// `POST /api/sessions/<id>/moveBack {resume, cwd}`: a moved session
    /// back here, its conversation given (`resume`) and, unless given, its
    /// folder as it is (a runner's folder isn't one here).
    func restMoveBack(_ call: RESTCall) -> HTTPResponse {
        let id = call.parts[1]
        let current = session(id)?.info.cwd ?? ""
        let cwd = call.body.cwd ?? (current.hasPrefix("/Volumes/") ? "" : current)
        switch moveBack(id, resume: call.body.resume ?? "", cwd: cwd, why: "moved back by request") {
        case .success: return .json(Envelope.sessions(session(id).map { [$0.info] } ?? []).encoded())
        case .failure(let refusal): return HTTPResponse(400, Envelope.error(refusal.reason).encoded())
        }
    }

    /// A remote as a runner clones it: https, which goes through MultiPass;
    /// GitHub's SSH form turned into its https URL. Nil for a local path.
    static func cloneURL(_ remote: String) -> String? {
        if remote.hasPrefix("https://") || remote.hasPrefix("http://") { return remote }
        if remote.hasPrefix("git@github.com:") { return "https://github.com/" + remote.dropFirst("git@github.com:".count) }
        if remote.hasPrefix("ssh://git@github.com/") { return "https://github.com/" + remote.dropFirst("ssh://git@github.com/".count) }
        return nil
    }

    /// `POST /api/sessions/<id>/moveToRunner {runsOn}`: the session, once
    /// its resume job is queued.
    func restMoveToRunner(_ call: RESTCall) async -> HTTPResponse {
        let runsOn = (call.body.runsOn ?? "").trimmingCharacters(in: .whitespaces)
        switch await moveToRunner(call.parts[1], runsOn: runsOn.isEmpty ? "container" : runsOn) {
        case .success:
            return .json(Envelope.sessions(session(call.parts[1]).map { [$0.info] } ?? []).encoded())
        case .failure(let refusal):
            return HTTPResponse(400, Envelope.error(refusal.reason).encoded())
        }
    }
}
