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
            // A session moved to a runner: where it works there now, which
            // a later agent of the session works in too (resumeDriven).
            if info.cwd != "~", !info.cwd.isEmpty {
                if record.info.cwd != info.cwd { record.info.cwd = info.cwd }
                record.move?.workingDirectory = info.cwd
            }
            if !record.isBound { bind(record) }
            if record.info.archived { record.setArchived(false) }
            setAgentState(record, .running)
            handOverInbox(record)
            // What waited for its agent (a start, a restart) goes over now.
            release(record)
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
    /// read before there was a driver, and gave it one that starts
    /// nothing), and its move known to the dispatcher again, whatever
    /// jobs.json kept: its runner's renewals and reports, and its wrapper's
    /// redial, are its session's. Its wrapper dials back and carries on;
    /// nothing starts it here. One whose agent doesn't come back has its
    /// job queued again (JobQueue.redialGrace), and says so.
    package func takeUpDrivenSessions() {
        guard let drivenProcess else { return }
        var moves: [AgentJobMove] = []
        var expected: Set<String> = []
        for record in sessions where record.driven {
            record.replaceProcess(drivenProcess(record.info))
            if record.move == nil, let kept = jobs?.kept(session: record.info.id) {
                record.move = kept
                Self.log("driven session \(record.info.title) (\(record.info.id)): its move taken from the dispatcher's jobs (agent \(kept.agent))")
            }
            guard let move = record.move, !move.agent.isEmpty else {
                Self.log("driven session \(record.info.title) (\(record.info.id)): which runner's agent carries it on isn't known here; "
                    + "it waits for its wrapper, or POST /api/sessions/\(record.info.id)/moveBack {resume} brings it back")
                record.notice = Self.dated("Visor doesn't know which runner's agent carries this session on. If it doesn't come back, "
                    + "move it back to this computer.")
                continue
            }
            moves.append(move)
            if !record.info.archived, record.info.agentState != .stopped { expected.insert(move.agent) }
        }
        jobs?.adopt(moves, expected: expected)
        if !moves.isEmpty || sessions.contains(where: \.driven) { saveArchiveNow() }
    }

    /// A job for a runner, from a client (an envelope as for a session: its
    /// agent, title, folder, model, and its first prompt as `text`).
    /// Deprecated (19 Nov 2026): agent jobs move to CI. The first in a run
    /// is logged, and the answer says so (`deprecated`).
    func restQueueJob(_ call: RESTCall) -> HTTPResponse {
        guard let jobs else { return HTTPResponse(404, Envelope.error("No runners take jobs here.").encoded()) }
        switch jobs.queueStart(call.body) {
        case .success(let id):
            Deprecated.queuedJob.noted(id)
            // The `job` envelope's fields, and the deprecation beside them.
            return .json(JSONValue.object(["type": .string("job"), "id": .string(id), "deprecated": .string(Deprecated.restNote)]).encoded())
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
        let projects = await ProjectSurvey.projects(cwd: cwd, conversation: conversation, home: SessionCatalog.home.path)
        if let unpushed = projects.first(where: { $0.unshared }) {
            return .failure(AgentJobRefusal("\(unpushed.path) has work that isn't pushed: push it first, so the runner's clone has it."))
        }
        let sources = projects.compactMap { project -> AgentJobSource? in
            guard let remote = project.remote.flatMap(Self.cloneURL) else { return nil }
            return AgentJobSource(repository: remote, ref: project.branch ?? "", name: (project.path as NSString).lastPathComponent)
        }
        var move = AgentJobMove(agent: UUID().uuidString.lowercased(), session: record.info.id, title: record.info.title,
                                model: record.info.model ?? "", effort: record.info.effort ?? "", resume: resume, cwd: cwd,
                                sources: sources, runsOn: runsOn)
        // The agent here goes first, then the session waits for the runner.
        let old = record.process
        await old.end(within: .seconds(5))
        record.replaceProcess(drivenProcess(record.info))
        record.driven = true
        // In a container, its permission prompts are skipped to begin with
        // (it touches only its volumes); a native runner's agent keeps the
        // session's own mode. Either says so in its job
        // (Job.skip_permissions): a session that asks, or is set to ask
        // later (its next agent's job), has its runner's agent ask through
        // the driver (DrivenProcess).
        if runsOn == "container" { record.setPermissions(skip: true) }
        move.skipPermissions = record.info.skipPermissions
        if case .failure(let refusal) = jobs.queueResume(move) {
            Self.log("moving \(record.info.title) to a runner: \(refusal.reason)")
            return .failure(refusal)
        }
        record.move = move
        // What an earlier move, or its coming back, said is past: a stale
        // notice is what misled visor#424.
        record.notice = nil
        setAgentState(record, .starting)
        Self.log("moving \(record.info.title) (\(record.info.id)) to a \(runsOn) runner, carrying on \(resume), with \(sources.count) repositories")
        saveArchiveNow()
        broadcastSessions()
        return .success(())
    }

    /// A moved session back on this computer, on its conversation in `cwd`
    /// ("": its folder as it is), with a notice saying why. Its runner's
    /// agent, if its wrapper takes it (protocol 2: HandingBackProcess) and
    /// `handBack` allows, is asked to hand the session back: to end and
    /// return its conversation, which the session then resumes, re-keyed for
    /// `cwd` (VisorServer+HandBack); answered at once, the session back once
    /// the conversation has come or been given up on (handBackEnded).
    /// Otherwise its agent is told to stop and the session carries on here
    /// from `resume`, the conversation it had before it moved. What a move
    /// that fails or is given up does on its own (VisorDriver's JobQueue,
    /// whose agent has ended: `handBack` false), and `POST
    /// /api/sessions/<id>/moveBack {resume, cwd}`. Unless `loud` is false
    /// (asked for by the person), every device that takes pushes is told
    /// too: a session never comes back unannounced.
    @discardableResult
    package func moveBack(_ id: String, resume: String, cwd: String, why: String, loud: Bool = true,
                          handBack: Bool = true) -> Result<Void, AgentJobRefusal> {
        guard let record = session(id) else { return .failure(AgentJobRefusal("No such session.")) }
        guard record.driven else { return .failure(AgentJobRefusal("“\(record.info.title)” runs on this computer already.")) }
        guard !resume.isEmpty else {
            return .failure(AgentJobRefusal("Which conversation “\(record.info.title)” carries on isn't known here: give it as `resume`."))
        }
        // Coming back already: that move back ends it.
        guard handingBack[record.info.id] == nil else {
            Self.log("\(record.info.title) (\(id)) is moving back already (\(why))")
            return .success(())
        }
        if handBack, let process = record.process as? HandingBackProcess, process.takesHandBack, !(record.move?.agent ?? "").isEmpty {
            startHandBack(record, process, resume: resume, cwd: cwd, why: why, loud: loud)
            return .success(())
        }
        // Its runner's agent had begun there (Started said its session):
        // what it said there stays there, and the notice says so.
        let started = !(record.move?.conversation ?? "").isEmpty
        bringBack(record, resume: resume, cwd: cwd, why: why, loud: loud,
                  notReturned: started ? "its runner's agent can't return its conversation" : nil)
        return .success(())
    }

    /// The driven session native again, on `resume` in `cwd`: its job let
    /// go, its runner's agent told to stop (unless it handed the session
    /// back, and has ended), a notice saying why, and its agent started
    /// here. `notReturned`: why its turns on the runner didn't come back,
    /// said in the notice.
    func bringBack(_ record: SessionRecord, resume: String, cwd: String, why: String, loud: Bool, handedBack: Bool = false,
                   notReturned: String? = nil) {
        let id = record.info.id
        jobs?.forget(session: id)
        if !handedBack { record.process.stop() }
        record.driven = false
        record.move = nil
        if !cwd.isEmpty { record.info.cwd = cwd }
        // Prompts skipped only in a container: here they are asked again,
        // before its agent starts (Claude takes the mode at launch).
        record.setPermissions(skip: false)
        record.replaceProcess(makeProcess(record.info, resume: resume))
        var said = handedBack ? "Back on this computer, with its turns on the runner: \(why)" : "Back on this computer: \(why)"
        if let notReturned {
            said += ". Its turns on the runner weren't returned (\(notReturned)): it carries on from where it was before it moved"
        }
        record.notice = Self.dated(said)
        Self.log("moved \(record.info.title) (\(id)) back to this computer, carrying on \(resume)\(handedBack ? ", handed back" : ""): \(why)")
        if loud { push(Self.pushName(for: record.info), "Back on this computer: \(why)", session: id, kind: "failed") }
        launchAgent(record)
        release(record)
        saveArchiveNow()
        broadcastSessions()
    }

    /// `POST /api/sessions/<id>/moveBack {resume, cwd}`: a moved session
    /// back here, answered once it is (its runner's agent handing it back
    /// first, when it can). `resume`, unless given, is the conversation it
    /// carries on as known here (knownConversation), so `{}` does; the one
    /// its runner's agent returns, if it does, comes first. Its folder,
    /// unless given, is as it is (a runner's folder isn't one here).
    func restMoveBack(_ call: RESTCall) async -> HTTPResponse {
        let id = call.parts[1]
        let record = session(id)
        let current = record?.info.cwd ?? ""
        let cwd = call.body.cwd ?? (current.hasPrefix("/Volumes/") ? "" : current)
        let resume = call.body.resume ?? record.map(knownConversation) ?? ""
        switch moveBack(id, resume: resume, cwd: cwd, why: "moved back by request", loud: false) {
        case .success:
            await handBackEnded(id)
            return .json(Envelope.sessions(session(id).map { [$0.info] } ?? []).encoded())
        case .failure(let refusal): return HTTPResponse(400, Envelope.error(refusal.reason).encoded())
        }
    }

    /// A remote as a runner clones it: https, which a container's proxy
    /// (Shireworks') carries; GitHub's SSH form turned into its https URL.
    /// Nil for a local path.
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
