// Sessions placed in this Mac's Sessions container (docs/containers.md,
// "Placing sessions"): a session is on this Mac or in its container, and
// moves between the two (Move to Container, Move Back). In the container,
// Visor starts the session's agent itself (agent_protocol's agent-wrapper,
// exec'd by the engine: SessionsContainer.startAgent) with a token of its
// own, and drives it as any driven session (DrivenProcess: its rows, mail,
// approvals, interrupts; the hand-back when it moves back). Nothing claims
// it: the dispatcher's queue isn't used.
//
// - Move to Container ends the agent here, and starts one in the container
//   on the same conversation (the driver's Conversation sends it down). A
//   session working under a folder the container shares (Sessions, the
//   checkouts' folder) keeps it; any other works in
//   `<Sessions>/Claude/<agent>`, with the repositories it worked in cloned
//   there (pushed first, as for a runner). Its prompts are skipped (the
//   container is its sandbox). One whose agent can't start there is moved
//   straight back.
// - Its agent's end, unless it was let go (Stop Agent, Restart Agent, Move
//   Back, archived or ended), starts another on its latest conversation:
//   the container restarted under it (an update of its image, a crash), or
//   its wrapper ended. Three quick ends in a row stop it instead, as does a
//   container held stopped (Stop, or turned off), each saying why.
// - A server's start (its update, a crash) takes the container down with
//   it: its sessions' agents are started again once the engine is given,
//   each on its latest conversation, a turn that was under way picked up
//   by a nudge, as a host session's is.

import Foundation
import VisorAgent
import VisorProtocol

extension VisorServer {
    /// Whether `record` is placed in the Sessions container.
    func isInContainer(_ record: SessionRecord) -> Bool {
        record.driven && record.move?.runsOn == ContainerRunner.runsOn
    }

    /// The sessions placed in the container whose agents should run: what
    /// keeps it from its idle stop, and starts it with the server.
    public var placedInContainer: Int {
        sessions.filter { isInContainer($0) && !$0.info.archived && $0.info.agentState != .stopped }.count
    }

    /// Move to Container: the session's agent here ended, and one started
    /// in the Sessions container on the same conversation. Refused for a
    /// session that isn't here, isn't Claude Code's, is archived or
    /// mid-turn, has no conversation yet, or works in a repository outside
    /// the container's folders with work not yet pushed; and while the
    /// container can't take sessions (off, no egress). Answered once its
    /// agent has started there (or the session is back, saying why not).
    package func moveToContainer(_ id: String) async -> Result<Void, AgentJobRefusal> {
        guard let container = sessionsContainer, drivenProcess != nil else {
            return .failure(AgentJobRefusal(Self.noContainerEngine))
        }
        guard let record = session(id) else { return .failure(AgentJobRefusal("No such session.")) }
        if let refusal = containerMoveRefusal(record) { return .failure(refusal) }
        let status = await container.status()
        guard status.takesSessions else { return .failure(AgentJobRefusal(Self.containerRefusal(status))) }
        guard let resume = record.process.resumeID, !resume.isEmpty else {
            return .failure(AgentJobRefusal("“\(record.info.title)” has no conversation to carry on yet."))
        }
        let shared = container.sharedFolders
        let cwd = (record.info.cwd as NSString).expandingTildeInPath
        let conversation = SessionCatalog.conversationFiles(agent: .claude, id: resume, cwd: cwd).first { !$0.folder }?.url
        let projects = await ProjectSurvey.projects(cwd: cwd, conversation: conversation, home: SessionCatalog.home.path)
        // What the container shares is there as it is; the rest is cloned.
        let outside = projects.filter { project in !shared.contains { Self.isInside(project.path, $0) } }
        if let unpushed = outside.first(where: { $0.unshared }) {
            return .failure(AgentJobRefusal("\(unpushed.path) has work that isn't pushed: push it first, so the container's clone has it."))
        }
        // Looked at again: the survey took a while.
        if let refusal = containerMoveRefusal(record) { return .failure(refusal) }
        let sources = outside.compactMap { project -> AgentJobSource? in
            guard let remote = project.remote.flatMap(Self.cloneURL) else { return nil }
            return AgentJobSource(repository: remote, ref: project.branch ?? "", name: (project.path as NSString).lastPathComponent)
        }
        let agent = UUID().uuidString.lowercased()
        guard let sessions = shared.first else { return .failure(AgentJobRefusal(Self.noSessionsShared)) }
        let folder = shared.contains { Self.isInside(cwd, $0) } ? cwd : "\(sessions)/Claude/\(agent)"
        let move = AgentJobMove(agent: agent, session: record.info.id, title: record.info.title, model: record.info.model ?? "",
                                effort: record.info.effort ?? "", resume: resume, cwd: cwd, sources: sources,
                                runsOn: ContainerRunner.runsOn, workingDirectory: folder, skipPermissions: true)
        // The agent here goes first.
        await record.process.end(within: .seconds(5))
        if let drivenProcess { record.replaceProcess(drivenProcess(record.info)) }
        record.driven = true
        // The container is its sandbox: its prompts are skipped there, as a
        // container runner's always were (#391), and asked again back here.
        record.setPermissions(skip: true)
        record.move = move
        record.notice = nil
        record.runsInContainer = true
        setAgentState(record, .starting)
        Self.log("moving \(record.info.title) (\(record.info.id)) into the Sessions container, carrying on \(resume) in \(folder)"
            + (sources.isEmpty ? "" : ", with \(sources.count) repositories cloned"))
        saveArchiveNow()
        broadcastSessions()
        return await startInContainer(record, first: true)
    }

    /// New Session in the Sessions container: a Claude Code session whose
    /// agent starts there, in a folder of its own on Sessions
    /// (`<Sessions>/Claude/<id>`, as this computer's sessions have), with
    /// `prompt` its first message if one is given. Its id, once its agent
    /// has started there; refused while the container can't take
    /// sessions, and, if its agent can't start, the session is removed.
    package func startSessionInContainer(title: String = "", model: String? = nil, effort: String? = nil,
                                         prompt: String? = nil) async -> Result<String, AgentJobRefusal> {
        guard let container = sessionsContainer, let drivenProcess else { return .failure(AgentJobRefusal(Self.noContainerEngine)) }
        let status = await container.status()
        guard status.takesSessions else { return .failure(AgentJobRefusal(Self.containerRefusal(status))) }
        guard let volume = container.sharedFolders.first else { return .failure(AgentJobRefusal(Self.noSessionsShared)) }
        let id = UUID().uuidString.lowercased()
        let folder = "\(volume)/Claude/\(id)"
        let named = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var info = SessionInfo(id: id, agent: .claude, cwd: folder, title: named.isEmpty ? "Claude Code (container)" : String(named.prefix(60)),
                               skipPermissions: true, model: model, effort: effort, created: Date().timeIntervalSince1970)
        info.agentState = .starting
        let record = SessionRecord(info: info, process: drivenProcess(info))
        record.driven = true
        record.runsInContainer = true
        record.move = AgentJobMove(agent: UUID().uuidString.lowercased(), session: id, title: info.title, model: model ?? "", effort: effort ?? "",
                                   resume: "", cwd: folder, runsOn: ContainerRunner.runsOn, workingDirectory: folder, skipPermissions: true)
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { record.enqueue(prompt) }
        sessions.append(record)
        Self.log("session started in the Sessions container: \(info.title) (\(id)) in \(folder)")
        saveArchiveNow()
        broadcastSessions()
        if case .failure(let refusal) = await startInContainer(record, first: false) {
            sessions.removeAll { $0 === record }
            saveArchiveNow()
            broadcastSessions()
            return .failure(refusal)
        }
        return .success(id)
    }

    /// `POST /api/container/sessions {title, model, effort, text}`: a new
    /// session in the container, once its agent has started there.
    func restStartSessionInContainer(_ call: RESTCall) async -> HTTPResponse {
        let body = call.body
        switch await startSessionInContainer(title: body.title ?? "", model: body.model, effort: body.effort, prompt: body.text) {
        case .success(let id):
            return .json(Envelope.sessions(session(id).map { [$0.info] } ?? []).encoded())
        case .failure(let refusal):
            return HTTPResponse(400, Envelope.error(refusal.reason).encoded())
        }
    }

    /// Why `record` can't move into the container now, if it can't.
    private func containerMoveRefusal(_ record: SessionRecord) -> AgentJobRefusal? {
        let title = record.info.title
        if isInContainer(record) { return AgentJobRefusal("“\(title)” is in the Sessions container already.") }
        if record.driven { return AgentJobRefusal("“\(title)” runs on a runner: move it back to this computer first.") }
        if record.info.agent != .claude { return AgentJobRefusal("The Sessions container carries on Claude Code sessions for now.") }
        if record.info.archived { return AgentJobRefusal("“\(title)” is archived: unarchive it first.") }
        if record.info.busy { return AgentJobRefusal("“\(title)” is working: move it once its turn has ended.") }
        if isHandingBack(record.info.id) { return AgentJobRefusal("“\(title)” is moving back already.") }
        return nil
    }

    /// What a session is told when the container shares no Sessions volume
    /// (its engine names it, from volumes.json: never a path assumed here).
    static let noSessionsShared = "The Sessions container shares no Sessions volume: make it with Visor Disk Utility."

    /// What a session is told when the container can't take it.
    static func containerRefusal(_ status: ContainerStatus) -> String {
        if !status.canRun { return "This Mac can't run the Sessions container: " + (status.errors.last ?? "it needs macOS 26 or later on Apple silicon.") }
        if !status.enabled { return "The Sessions container is off: turn it on in Settings › Sessions Container." }
        if status.state == .noEgress { return "The Sessions container has no egress (\(status.egress ?? "its check failed")): Check Again in Settings." }
        return "The Sessions container can't take sessions now (\(status.state.rawValue))."
    }

    /// `record`'s move's agent started in the container: known to the
    /// runner first (its wrapper may dial in at once), with its own token,
    /// on its latest conversation, in the folder it works in there, and
    /// watched to its end. One that can't start, on its first move in,
    /// brings its session straight back; later, stops it and says why.
    @discardableResult
    func startInContainer(_ record: SessionRecord, first: Bool) async -> Result<Void, AgentJobRefusal> {
        guard let move = record.move, !move.agent.isEmpty, isInContainer(record) else {
            return .failure(AgentJobRefusal("“\(record.info.title)” isn't placed in the Sessions container."))
        }
        // Who it commits as, asked of agent-proxy first (found once, then
        // kept): the guards below see the session as it is once answered.
        let git = await containerGitIdentityForStart()
        guard record.move?.agent == move.agent, isInContainer(record) else {
            return .failure(AgentJobRefusal("“\(record.info.title)” isn't placed in the Sessions container."))
        }
        let id = record.info.id
        let agent = ContainerRunner.key(move.agent)
        guard let container = sessionsContainer else {
            containerRunner.waiting.insert(id)
            return .failure(AgentJobRefusal(Self.noContainerEngine))
        }
        guard let sessions = container.sharedFolders.first else { return .failure(AgentJobRefusal(Self.noSessionsShared)) }
        containerRunner.place(agent, session: id, resume: move.resume, cwd: move.cwd)
        let harness = containerRunner.harness
        let request = ContainerAgent(
            agent: agent, session: id, title: move.title, harness: harness == "claude" ? nil : harness,
            model: move.model.isEmpty ? nil : move.model, effort: move.effort.isEmpty ? nil : move.effort,
            workingDirectory: move.workingDirectory, resumeSessionID: move.resumeOnRunner, skipPermissions: move.skipPermissions,
            sources: move.sources.map { ContainerAgent.Source(repository: $0.repository, ref: $0.ref, name: $0.name) },
            sourcesDirectory: move.sources.isEmpty ? nil : move.workingDirectory, token: containerRunner.token(for: agent),
            // The container's Claude folder is on Sessions, so what its
            // agents say survives the container, and the host can read it;
            // its credential is agent-proxy's, a placeholder here; it
            // commits as the GitHub App's bot, where agent-proxy has one.
            environment: Self.containerClaudeEnvironment(sessions: sessions, git: git))
        do {
            let run = try await container.startAgent(request)
            containerRunner.started(agent, run: run)
            Self.log("container: \(agent) started for \(record.info.title) (\(id)), carrying on \(move.resumeOnRunner) in \(move.workingDirectory)")
            Task { [weak self] in
                let status = await run.wait()
                await self?.containerAgentEnded(agent, status: status)
            }
            return .success(())
        } catch {
            _ = containerRunner.ended(agent)
            let why = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Self.log("container: \(agent) for \(record.info.title) (\(id)) didn't start: \(why)")
            // Moving back meanwhile: it ends now, without it.
            if isHandingBack(id) { handBackFailed(id, agent: agent, why: "its agent couldn't start in the Sessions container: \(why)") }
            guard record.move?.agent.lowercased() == agent, isInContainer(record) else { return .failure(AgentJobRefusal(why)) }
            if first {
                moveBack(id, resume: move.resume, cwd: move.cwd, why: "it couldn't start in the Sessions container: \(why)", handBack: false)
            } else {
                holdInContainer(record, "Its agent couldn't start in the Sessions container: \(why). Start Agent tries again; "
                    + "Move Back brings it to this computer.")
            }
            return .failure(AgentJobRefusal("It couldn't start in the Sessions container: \(why)"))
        }
    }

    /// The container agent `agent` has ended with `status`: unless it was
    /// let go, its session's next agent started there, or the session
    /// stopped saying why (the container held stopped or unable to take
    /// it, or three quick ends in a row).
    func containerAgentEnded(_ agent: String, status: Int32) async {
        guard let placed = containerRunner.ended(agent) else { return }
        Self.log("container: \(agent) of \(placed.session) ended with \(status)\(placed.released ? " (let go)" : "")")
        guard !placed.released, let record = session(placed.session), wantsContainerAgent(record, agent) else { return }
        let lasted = containerRunner.now().timeIntervalSince(placed.started)
        let state = await sessionsContainer?.status()
        // Asked of the container meanwhile: still wanted?
        guard wantsContainerAgent(record, agent), let state else { return }
        let id = record.info.id
        if let held = state.held {
            containerRunner.quickEnds[id] = nil
            return holdInContainer(record, "Its agent in the Sessions container ended, as \(held). Start Agent carries it on there; "
                + "Move Back brings it to this computer.")
        }
        guard state.takesSessions else {
            containerRunner.quickEnds[id] = nil
            return holdInContainer(record, "Its agent in the Sessions container ended, and the container can't take it now. "
                + Self.containerRefusal(state))
        }
        // The container started again after it did: a restart (an image's
        // update, a crash), not an agent that didn't get going.
        let restartedUnder = (state.since ?? 0) > placed.started.timeIntervalSince1970
        let quick = !restartedUnder && lasted < ContainerRunner.quickEnd
        let count = quick ? (containerRunner.quickEnds[id] ?? 0) + 1 : 0
        containerRunner.quickEnds[id] = count
        if count >= ContainerRunner.quickEndsAllowed {
            containerRunner.quickEnds[id] = nil
            return holdInContainer(record, "Its agent in the Sessions container ended \(count) times as it started (the last with \(status)); "
                + "its log is Containers/sessions/logs/\(agent).log on the Visor volume. Start Agent tries again; Move Back brings it to this computer.")
        }
        let why = restartedUnder ? "carrying on, as the Sessions container restarted under it, the agent of"
                                 : "carrying on, as its agent there ended (\(status)), the agent in the Sessions container of"
        resumeInContainer(record, why: why, after: quick ? .seconds(count) : .zero)
    }

    /// Whether `record`'s agent `agent` is still the one it should have
    /// running in the container.
    private func wantsContainerAgent(_ record: SessionRecord, _ agent: String) -> Bool {
        isInContainer(record) && record.move?.agent.lowercased() == ContainerRunner.key(agent) && !record.info.archived
            && !isHandingBack(record.info.id) && record.info.agentState != .stopped && record.info.agentState != .stopping
    }

    /// A container session's next agent: a new id (the one before may
    /// still be on its way out, and is let go), on the conversation it
    /// carries on, in the folder it worked in there, with its settings as
    /// they are now; started after `pause`. Starting, then running once
    /// its wrapper dials in. Without the engine (yet), it waits for it.
    @discardableResult
    func resumeInContainer(_ record: SessionRecord, why: String, after pause: Duration = .zero) -> Bool {
        guard var move = record.move, isInContainer(record) else { return false }
        // The agent before is told to stop, and ended there if it doesn't.
        if !move.agent.isEmpty {
            record.process.stop()
            containerRunner.release(move.agent)
        }
        if let drivenProcess { record.replaceProcess(drivenProcess(record.info)) }
        move.agent = UUID().uuidString.lowercased()
        move.title = record.info.title
        move.model = record.info.model ?? ""
        move.effort = record.info.effort ?? ""
        move.skipPermissions = record.info.skipPermissions
        record.move = move
        if record.info.busy {
            broadcast(record.apply(.activity(nil)), session: record)
            handle(.busy(false), from: record)
        }
        setAgentState(record, .starting)
        saveArchiveNow()
        broadcastSessions()
        guard sessionsContainer != nil else {
            containerRunner.waiting.insert(record.info.id)
            Self.log("\(record.info.title) (\(record.info.id)) waits for the Sessions container, which this server doesn't have yet")
            return false
        }
        Self.log("\(why) \(record.info.title) (\(record.info.id)) as \(move.agent), carrying on \(move.resumeOnRunner)")
        Task { [weak self] in
            if pause > .zero { try? await Task.sleep(for: pause) }
            guard let self, record.move?.agent == move.agent, self.isInContainer(record) else { return }
            await self.startInContainer(record, first: false)
        }
        return true
    }

    /// A container session stopped, its agent's end said in a notice: it
    /// waits for Start Agent (or Move Back).
    private func holdInContainer(_ record: SessionRecord, _ words: String) {
        Self.log("\(record.info.title) (\(record.info.id)): \(words)")
        broadcast(record.apply(.notice(Self.dated(words))), session: record)
        if record.info.busy {
            broadcast(record.apply(.activity(nil)), session: record)
            handle(.busy(false), from: record)
        }
        setAgentState(record, .stopped)
        saveArchiveNow()
        broadcastSessions()
    }

    /// The sessions placed in the container whose agents ran when this
    /// server last stopped (taken up from sessions.json), started again in
    /// it, once the engine is given: each on its latest conversation, and
    /// one whose turn was cut short told to pick it up first, as a host
    /// session is.
    func resumeContainerSessions() {
        guard sessionsContainer != nil, drivenProcess != nil else { return }
        let waiting = containerRunner.waiting
        containerRunner.waiting = []
        for id in waiting.sorted() {
            guard let record = session(id), isInContainer(record), !record.info.archived, record.info.agentState != .stopped else { continue }
            if record.interrupted {
                record.interrupted = false
                record.enqueue(Self.resumeNudge, images: [], first: true, origin: .system)
            }
            resumeInContainer(record, why: "carrying on, after the server's start, the agent in the Sessions container of")
        }
    }

    /// `POST /api/sessions/<id>/moveToContainer`: the session, once its
    /// agent has started in the container.
    func restMoveToContainer(_ call: RESTCall) async -> HTTPResponse {
        switch await moveToContainer(call.parts[1]) {
        case .success:
            return .json(Envelope.sessions(session(call.parts[1]).map { [$0.info] } ?? []).encoded())
        case .failure(let refusal):
            return HTTPResponse(400, Envelope.error(refusal.reason).encoded())
        }
    }

    /// Whether `path` is `folder` or under it, with no `..` to leave it.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return false }
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return path == base || path.hasPrefix(base + "/")
    }
}
