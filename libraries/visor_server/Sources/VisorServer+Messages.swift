// What clients say over the socket, and what agents ask of the other
// sessions.

import ClaudeTranscript
import MessageCache
import Foundation
import VisorProtocol

extension VisorServer {
    func handle(_ envelope: Envelope, from client: ClientConnection) {
        // The permission shim: one request per connection, answered later.
        if envelope.type == "approval_request" {
            guard envelope.token == agentToken, let record = session(envelope.session), let id = envelope.id else {
                client.sendLast(.error("Not an agent of this host"))
                return
            }
            let questions = envelope.questions?.isEmpty == false ? envelope.questions : nil
            let request = ApprovalRequest(id: id, tool: envelope.text ?? "tool", summary: envelope.prompt ?? "", questions: questions)
            record.approvalWaiters[id] = client
            record.setPendingApproval(request)
            broadcast(.approval(session: record.info.id, request), session: record)
            broadcastSessions()
            return
        }
        // Sessions talking to each other, through the Visor MCP server each
        // agent runs: one request per connection, answered at once.
        if envelope.type == "agent" {
            answerAgent(envelope) { reply in client.sendLast(reply) }
            return
        }
        if !client.authenticated {
            guard envelope.type == "login" else { client.send(.error("Log in first")); return }
            let token = envelope.token ?? ""
            let byPassword = !password.isEmpty && (envelope.password ?? "") == password
            guard client.trusted || settings.asksNothing || byPassword || (!token.isEmpty && tokens.contains(token)) else {
                client.sendLast(.error("Wrong password"))
                return
            }
            client.authenticated = true
            var welcome = Envelope.welcome(host: hostName, sessions: sessions.map(\.info), catalogs: catalogs())
            // Whether a session can start in a container here: New
            // Session offers it only then.
            welcome.container = containersAvailable
            client.send(welcome)
            return
        }
        perform(envelope, from: client)
    }

    /// A command, from a WebSocket client or the REST side (no client).
    func perform(_ envelope: Envelope, from client: ClientConnection?) {
        switch envelope.type {
        case "start": performStart(envelope, from: client)
        case "send": performSend(envelope)
        case "stop": performStop(envelope)
        case "unqueue": performUnqueue(envelope)
        case "acknowledge": performAcknowledge(envelope)
        case "earlier": performEarlier(envelope, from: client)
        case "subscribe": performSubscribe(envelope, from: client)
        case "unsubscribe": performUnsubscribe(envelope, from: client)
        case "signIn": performSignIn(envelope)
        case "permissions": performPermissions(envelope)
        case "approve": performApprove(envelope)
        case "settings": performSettings(envelope)
        case "rename": performRename(envelope)
        case "archive": performArchive(envelope)
        case "unarchive": performUnarchive(envelope)
        case "restart": performRestart(envelope, from: client)
        case "restartAgent": performRestartAgent(envelope)
        case "stopAgent": performStopAgent(envelope)
        case "startAgent": performStartAgent(envelope)
        case "keepBranch": performKeepBranch(envelope)
        case "continueBranch": performContinueBranch(envelope)
        case "end": performEnd(envelope)
        case "fork": performFork(envelope, from: client)
        case "side": performSide(envelope)
        case "endSide": performEndSide(envelope)
        case "toSubagent": performToSubagent(envelope, from: client)
        case "closeSubagent": performCloseSubagent(envelope)
        case "mcp": performMCPSwitch(envelope, from: client)
        case "contain": performContain(envelope, from: client)
        // A client's heartbeat: answered at once, to that client only.
        case "ping": client?.send(.pong())
        // What a client of 0.31 or before says to a terminal session:
        // there are none here to take it, and an error would read there
        // as a failed connection.
        case "mode", "input", "resize": break
        default:
            client?.send(.error("Unknown message \(envelope.type)"))
        }
    }

    private func performStart(_ envelope: Envelope, from client: ClientConnection?) {
        // Its agent in a container here: the container made first.
        if envelope.container == true {
            return startInContainer(envelope, from: client) { result in
                if case .failure(let failure) = result { client?.send(.error(failure.message)) }
            }
        }
        guard let agent = envelope.agent else { return }
        let id = envelope.id ?? UUID().uuidString
        let cwd = (envelope.cwd?.isEmpty == false ? envelope.cwd! : "~")
        let skip = envelope.skipPermissions ?? true
        let given = (envelope.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Sessions live under their folder (the project), so the default
        // name is the agent's, numbered within the project.
        let resolvedCWD = HostFolders.resolve(cwd)
        let siblings = sessions.filter { HostFolders.resolve($0.info.cwd) == resolvedCWD && $0.info.agent == agent }.count
        let title = given.isEmpty ? "\(agent.title) \(siblings + 1)" : String(given.prefix(60))
        let resume = (envelope.resume ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let info = SessionInfo(id: id, agent: agent, cwd: cwd, title: title, skipPermissions: skip, created: Date().timeIntervalSince1970)
        // A resumed session shows what was said before it moved here.
        let past = resume.isEmpty ? [] : (harnesses.harness(for: agent)?.transcript(id: resume, cwd: cwd, limit: SessionRecord.servedRows) ?? [])
        let record = SessionRecord(info: info, process: makeProcess(info, resume: resume.isEmpty ? nil : resume), entries: past)
        if !resume.isEmpty { record.refreshResume() }
        sessions.append(record)
        if let client { record.subscribers.insert(ObjectIdentifier(client)) }
        Self.log("session started: \(title) (\(agent.title)) in \(cwd)\(resume.isEmpty ? "" : ", resuming \(resume)")")
        saveArchive()
        broadcastSessions()
    }

    private func performSend(_ envelope: Envelope) {
        guard let record = session(envelope.session), let text = envelope.text else { return }
        // Writing to an archived session brings it back, same parameters.
        if record.info.archived { unarchive(record) }
        deliver(text, to: record, images: envelope.images ?? [])
    }

    private func performStop(_ envelope: Envelope) {
        guard let record = session(envelope.session) else { return }
        // The turn ends; the process stays. A Claude chat takes a control
        // message, and anything without its own way to end a turn falls
        // back to stopping (Codex spawns per turn, so the next message
        // starts a fresh one regardless).
        record.process.interrupt()
    }

    /// No `text`: drop the lot. With one: drop that message.
    private func performUnqueue(_ envelope: Envelope) {
        guard let record = session(envelope.session) else { return }
        record.unqueue(envelope.text)
        saveArchive()
        broadcastSessions()
    }

    private func performAcknowledge(_ envelope: Envelope) {
        guard let record = session(envelope.session) else { return }
        record.notice = nil
        stateChanged(record)
        saveArchive()
    }

    /// Rows before the first one the client shows, from what is
    /// here or from the cache.
    private func performEarlier(_ envelope: Envelope, from client: ClientConnection?) {
        guard let client, let record = session(envelope.session), let before = envelope.before else { return }
        Task { client.send(await record.earlier(before: before)) }
    }

    /// The client left the session: nothing more of it goes there until it
    /// follows the session again.
    private func performUnsubscribe(_ envelope: Envelope, from client: ClientConnection?) {
        guard let client, let record = session(envelope.session) else { return }
        record.subscribers.remove(ObjectIdentifier(client))
    }

    private func performSubscribe(_ envelope: Envelope, from client: ClientConnection?) {
        guard let client, let record = session(envelope.session) else { return }
        record.subscribers.insert(ObjectIdentifier(client))
        // Bound before any turn: what the file says reaches subscribers
        // whether or not an agent of ours has run.
        if !record.isBound { bind(record) }
        record.followFileIfNeeded()
        client.send(record.transcriptEnvelope)
        // Everything that is not the record, in one piece, so a window
        // that opens mid-turn misses none of it.
        client.send(record.ephemeralEnvelope)
    }

    private func performPermissions(_ envelope: Envelope) {
        guard let record = session(envelope.session), let skip = envelope.skipPermissions else { return }
        guard record.info.skipPermissions != skip else { return }
        record.setPermissions(skip: skip)
        // Claude's mode is a launch flag: the process restarts (resumed by
        // session id) once idle. Codex spawns per turn and just picks it up.
        if record.info.agent == .claude {
            if record.info.busy { record.restartWhenIdle = true } else { record.process.stop() }
        }
        broadcastSessions()
    }

    private func performApprove(_ envelope: Envelope) {
        guard let record = session(envelope.session), let id = envelope.id, let allow = envelope.allow else { return }
        // A question the agent itself asked (Codex's): answered to it.
        guard let waiter = record.approvalWaiters.removeValue(forKey: id) else {
            guard let pending = record.info.pendingApproval, pending.id == id, pending.questions != nil else { return }
            record.process.answer(id, with: allow ? envelope.answers : nil)
            record.setPendingApproval(nil)
            broadcast(.approval(session: record.info.id, nil), session: record)
            broadcastSessions()
            return
        }
        var answer = Envelope(type: "approval_result")
        answer.id = id
        answer.busy = allow
        // A question's answers, for the agent's own tool input.
        answer.answers = envelope.answers
        waiter.sendLast(answer)
        if record.info.pendingApproval?.id == id { record.setPendingApproval(nil) }
        broadcast(.approval(session: record.info.id, record.info.pendingApproval), session: record)
        broadcastSessions()
    }

    private func performSettings(_ envelope: Envelope) {
        guard let record = session(envelope.session) else { return }
        let model = envelope.model ?? record.info.model
        let effort = envelope.effort ?? record.info.effort
        guard model != record.info.model || effort != record.info.effort else { return }
        record.setSettings(model: model, effort: effort)
        saveArchive()
        // Claude's flags are launch flags: restart (resumed) once idle.
        if record.info.agent == .claude {
            if record.info.busy { record.restartWhenIdle = true } else { record.process.stop() }
        }
        broadcastSessions()
    }

    private func performRename(_ envelope: Envelope) {
        guard let record = session(envelope.session) else { return }
        let title = (envelope.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        record.setTitle(String(title.prefix(60)))
        saveArchive()
        broadcastSessions()
    }

    private func performArchive(_ envelope: Envelope) {
        guard let record = session(envelope.session), !record.info.archived else { return }
        archive(record)
    }

    private func performUnarchive(_ envelope: Envelope) {
        guard let record = session(envelope.session), record.info.archived else { return }
        unarchive(record)
    }

    private func performKeepBranch(_ envelope: Envelope) {
        guard let record = session(envelope.session), record.wentOnElsewhere else { return }
        record.keepBranch()
        saveArchive()
        broadcastSessions()
    }

    private func performContinueBranch(_ envelope: Envelope) {
        guard let record = session(envelope.session), record.wentOnElsewhere else { return }
        continueOtherBranch(record)
    }

    /// A running agent restarted. A stopped one is started (what a client
    /// of 0.34 or before, which offers only Restart, means by it); one
    /// starting or stopping is left to get there.
    /// Into its container, or out of it: what fails is said to the client
    /// that asked.
    private func performContain(_ envelope: Envelope, from client: ClientConnection?) {
        guard let record = session(envelope.session), let into = envelope.container else { return }
        contain(record, into: into, size: envelope.containerSize) { result in
            if case .failure(let failure) = result { client?.send(.error(failure.message)) }
        }
    }

    private func performRestartAgent(_ envelope: Envelope) {
        guard let record = session(envelope.session), !record.info.archived else { return }
        switch record.info.agentState {
        case .running?: restartAgent(record)
        case .stopped?: startAgent(record)
        default: break
        }
    }

    private func performStopAgent(_ envelope: Envelope) {
        guard let record = session(envelope.session), !record.info.archived, record.info.agentState == .running else { return }
        stopAgent(record)
    }

    private func performStartAgent(_ envelope: Envelope) {
        guard let record = session(envelope.session), !record.info.archived, record.info.agentState == .stopped else { return }
        startAgent(record)
    }

    /// Quitting the app kills every agent, so an agent that wants a
    /// new build of the server cannot install it itself: it dies
    /// half-way. Here the server does it — a relauncher that outlives
    /// us swaps the bundle and starts it again, naming the sessions
    /// to carry on (this one included, by default).
    private func performRestart(_ envelope: Envelope, from client: ClientConnection?) {
        var carry = sessions.filter(\.info.busy).map(\.info.id)
        if let named = envelope.session, !carry.contains(named) { carry.append(named) }
        if let message = relaunch(installing: envelope.path, carrying: carry) {
            client?.send(.error(message))
        }
    }

    private func performEnd(_ envelope: Envelope) {
        guard let record = session(envelope.session) else { return }
        record.process.stop()
        record.markEnded()
        // Its container goes with it, unless a fork or branch of it, or the
        // session it was made from, still runs there.
        if let container = record.info.container,
           !sessions.contains(where: { $0 !== record && $0.info.container?.id == container.id }) {
            removeContainer(container)
        }
        sessions.removeAll { $0 === record }
        mcpProxy.forget(session: record.info.id)
        dropWaiters(for: record.info.id)
        Self.log("session ended: \(record.info.title)")
        saveArchive()
        broadcastSessions()
    }

    /// What an agent asked of the other sessions, answered: `mode` is the
    /// ask, `client` the asking session, `session` the one it is about.
    /// Only the agents this server started hold the token.
    func agentReply(_ envelope: Envelope) -> Envelope {
        guard envelope.token == agentToken, let caller = session(envelope.client) else {
            var reply = Envelope(type: "agent_result")
            reply.id = envelope.id
            reply.error = "Not an agent of this computer"
            return reply
        }
        return answer(envelope, from: caller.info.id, named: caller.displayName, on: nil)
    }

    /// What heads a message from one agent to another: the session and the
    /// computer it came from and the one it is for, each by name and id, so
    /// an agent never takes it for the user's or for another session's,
    /// and answers exactly where it came from.
    static func agentMessageHeader(from: RelayEndpoint, to: RelayEndpoint) -> String {
        "[Message from the Visor session “\(from.sessionName)” (\(from.session)) on \(from.serverName) (server \(from.server)), "
            + "to this session “\(to.sessionName)” (\(to.session)) on \(to.serverName) — not from the user. "
            + "To answer, use send_message with session \(from.session) and server \(from.server).]"
    }

    /// The ask answered for this server's sessions: from one of its own
    /// agents, or (`computer` set) from an agent on another server whose
    /// message a client carried here.
    func answer(_ envelope: Envelope, from caller: String, named name: String, on computer: RelayEndpoint?) -> Envelope {
        var reply = Envelope(type: "agent_result")
        reply.id = envelope.id
        let others = sessions.filter { $0.info.id != caller && !$0.info.ended && !$0.info.archived }
        switch envelope.mode {
        case "sessions":
            reply.text = others.isEmpty ? "No other sessions." : others.map { record in
                let info = record.info
                return "\(info.id) — \(record.displayName) (\(info.agent.title), \(info.busy ? "working" : "idle")) in \(info.cwd)"
            }.joined(separator: "\n")
        case "send":
            guard let target = others.first(where: { $0.info.id == envelope.session }) else {
                reply.error = "No other session with that id; list_sessions names them."
                return reply
            }
            guard let text = envelope.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                reply.error = "Nothing to send."
                return reply
            }
            // Marked as another agent's, so it is not taken for the user's:
            // who sent it (session and computer, by name and id), who it is
            // for, and exactly how to answer.
            let from = computer ?? RelayEndpoint(server: id, serverName: hostName, session: caller, sessionName: name)
            let marked = Self.agentMessageHeader(from: from, to: RelayEndpoint(server: id, serverName: hostName, session: target.info.id,
                                                                               sessionName: target.displayName)) + "\n\n" + text
            let busy = target.info.busy
            deliver(marked, to: target)
            let to = "“\(target.displayName)” (\(target.info.id)) on \(hostName)"
            reply.text = busy ? "Queued for \(to): it is working and takes it when its turn ends." : "Sent to \(to)."
            reply.busy = busy
        case "read":
            guard let target = others.first(where: { $0.info.id == envelope.session }) else {
                reply.error = "No other session with that id; list_sessions names them."
                return reply
            }
            let count = max(1, min(envelope.rows ?? 10, 50))
            reply.text = target.entries.suffix(count).map { row in
                let words = row.text.count > 2000 ? String(row.text.prefix(2000)) + "…" : row.text
                let calls = row.activities.isEmpty ? "" : " [" + row.activities.joined(separator: "; ") + "]"
                return "\(row.role.rawValue): \(words)\(calls)"
            }.joined(separator: "\n\n")
        default:
            reply.error = "Unknown request"
        }
        return reply
    }
}
