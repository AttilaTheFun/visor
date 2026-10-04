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
            let request = ApprovalRequest(id: id, tool: envelope.text ?? "tool", summary: envelope.prompt ?? "")
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
            guard byPassword || (!token.isEmpty && tokens.contains(token)) else {
                client.sendLast(.error("Wrong password"))
                return
            }
            client.authenticated = true
            client.clientID = envelope.client ?? ""
            client.send(.welcome(host: hostName, sessions: sessions.map(\.info), catalogs: catalogs()))
            return
        }
        perform(envelope, from: client)
    }

    /// A command, from a WebSocket client or the REST side (no client).
    func perform(_ envelope: Envelope, from client: ClientConnection?) {
        switch envelope.type {
        case "start": performStart(envelope, from: client)
        case "mode": performMode(envelope, from: client)
        case "input": performInput(envelope, from: client)
        case "resize": performResize(envelope, from: client)
        case "send": performSend(envelope)
        case "stop": performStop(envelope)
        case "unqueue": performUnqueue(envelope)
        case "acknowledge": performAcknowledge(envelope)
        case "earlier": performEarlier(envelope, from: client)
        case "subscribe": performSubscribe(envelope, from: client)
        case "permissions": performPermissions(envelope)
        case "approve": performApprove(envelope)
        case "settings": performSettings(envelope)
        case "rename": performRename(envelope)
        case "archive": performArchive(envelope)
        case "unarchive": performUnarchive(envelope)
        case "restart": performRestart(envelope, from: client)
        case "end": performEnd(envelope)
        // A client's heartbeat: answered at once, to that client only.
        case "ping": client?.send(.pong())
        default:
            client?.send(.error("Unknown message \(envelope.type)"))
        }
    }

    private func performStart(_ envelope: Envelope, from client: ClientConnection?) {
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
        let past = resume.isEmpty ? [] : (harnesses.harness(for: agent)?.transcript(id: resume, cwd: cwd, limit: 300) ?? [])
        let record = SessionRecord(info: info, process: makeProcess(info, resume: resume.isEmpty ? nil : resume), entries: past)
        if !resume.isEmpty { record.refreshResume() }
        sessions.append(record)
        if let client { record.subscribers.insert(ObjectIdentifier(client)) }
        Self.log("session started: \(title) (\(agent.title)) in \(cwd)\(resume.isEmpty ? "" : ", resuming \(resume)")")
        saveArchive()
        broadcastSessions()
    }

    /// A window takes a terminal session: from now on the shell is drawn
    /// for it, at its size — started if it is not running, kept if it is —
    /// and whoever had it before is sent nothing more. What the shell has
    /// shown so far goes to the window that took it. A chat session has no
    /// terminal to take.
    private func performMode(_ envelope: Envelope, from client: ClientConnection?) {
        guard let record = session(envelope.session), record.info.agent.isShell, envelope.mode == "tui" else { return }
        // Drawn for one window: without a client and its size there is
        // nothing to draw for.
        let controller = client?.clientID ?? envelope.controller ?? ""
        guard !controller.isEmpty, let cols = envelope.cols, let rows = envelope.rows, cols > 0, rows > 0 else { return }
        if record.info.archived { unarchive(record) }
        record.setMode(.tui(controller: controller, cols: cols, rows: rows))
        launchTerminal(record)
        if let client {
            // Taking it is asking for what it draws.
            record.subscribers.insert(ObjectIdentifier(client))
            replayTerminal(record, to: client)
        }
        broadcastSessions()
    }

    /// What the shell has shown, whole, to the window it is drawn for —
    /// marked as a replay (its size set), so the window starts its screen
    /// over rather than adding to it — and then the shell asked to draw
    /// itself again, since what runs on it owns every cell and its own
    /// painting is the only thing that is certainly true.
    func replayTerminal(_ record: SessionRecord, to client: ClientConnection) {
        if let size = record.info.mode.terminalSize {
            var replay = Envelope.tty(session: record.info.id, data: record.scrollback.base64EncodedString())
            replay.cols = size.cols
            replay.rows = size.rows
            client.send(replay)
        }
        record.terminal?.repaint()
    }

    private func performInput(_ envelope: Envelope, from client: ClientConnection?) {
        guard let record = session(envelope.session), record.info.mode.controlled(by: client?.clientID),
              let data = envelope.data.flatMap({ Data(base64Encoded: $0) }) else { return }
        record.terminal?.write(data)
    }

    /// The controller's window changed: the terminal is re-drawn
    /// for it, and the mode remembers the new shape.
    private func performResize(_ envelope: Envelope, from client: ClientConnection?) {
        guard let record = session(envelope.session), record.info.mode.controlled(by: client?.clientID),
              let controller = record.info.mode.controller,
              let cols = envelope.cols, let rows = envelope.rows, cols > 0, rows > 0 else { return }
        guard record.info.mode.terminalSize.map({ $0 != (cols, rows) }) ?? true else { return }
        record.setMode(.tui(controller: controller, cols: cols, rows: rows))
        record.terminal?.resize(cols: cols, rows: rows)
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
        // The turn ends; the process stays. A terminal takes Escape, a
        // Claude chat a control message, and anything without its own
        // way to end a turn falls back to stopping (Codex spawns per
        // turn, so the next message starts a fresh one regardless).
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
        saveArchive()
    }

    /// Rows before the first one the client shows, from what is
    /// here or from the cache.
    private func performEarlier(_ envelope: Envelope, from client: ClientConnection?) {
        guard let client, let record = session(envelope.session), let before = envelope.before else { return }
        Task { client.send(await record.earlier(before: before)) }
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
        // A terminal session's screen goes to the one window it is drawn
        // for, and to no other.
        if record.info.mode.controlled(by: client.clientID) { replayTerminal(record, to: client) }
    }

    private func performPermissions(_ envelope: Envelope) {
        guard let record = session(envelope.session), !record.info.agent.isShell, let skip = envelope.skipPermissions else { return }
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
        guard let record = session(envelope.session), let id = envelope.id, let allow = envelope.allow,
              let waiter = record.approvalWaiters.removeValue(forKey: id) else { return }
        var answer = Envelope(type: "approval_result")
        answer.id = id
        answer.busy = allow
        waiter.sendLast(answer)
        if record.info.pendingApproval?.id == id { record.setPendingApproval(nil) }
        broadcast(.approval(session: record.info.id, record.info.pendingApproval), session: record)
        broadcastSessions()
    }

    private func performSettings(_ envelope: Envelope) {
        guard let record = session(envelope.session), !record.info.agent.isShell else { return }
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
        sessions.removeAll { $0 === record }
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
        let name = caller.info.title.isEmpty ? caller.info.agent.title : caller.info.title
        return answer(envelope, from: caller.info.id, named: name, on: nil)
    }

    /// The same asks from an agent on a linked computer, which that
    /// computer's server forwards (`POST /api/agent`): `client` is the
    /// caller as `<computer>/<id>`, `title` its name, `host` the computer.
    func linkedAgentReply(_ envelope: Envelope) -> Envelope {
        guard let caller = envelope.client, caller.contains("/") else {
            var reply = Envelope(type: "agent_result")
            reply.id = envelope.id
            reply.error = "Not an agent of a linked computer"
            return reply
        }
        return answer(envelope, from: caller, named: envelope.title ?? caller, on: envelope.host)
    }

    func answer(_ envelope: Envelope, from caller: String, named name: String, on computer: String?) -> Envelope {
        var reply = Envelope(type: "agent_result")
        reply.id = envelope.id
        let others = sessions.filter { $0.info.id != caller && !$0.info.ended && !$0.info.archived }
        switch envelope.mode {
        case "sessions":
            reply.text = others.isEmpty ? "No other sessions." : others.map { record in
                let info = record.info
                return "\(info.id) — \(info.title.isEmpty ? info.agent.title : info.title) (\(info.agent.title), \(info.busy ? "working" : "idle")) in \(info.cwd)"
            }.joined(separator: "\n")
        case "send":
            guard let target = others.first(where: { $0.info.id == envelope.session }) else {
                reply.error = "No other session with that id; list_sessions names them."
                return reply
            }
            // A terminal is typed into by the person at its window; an
            // agent has its own shell for commands.
            guard !target.info.agent.isShell else {
                reply.error = "That session is a terminal: it is typed into from its window, not sent messages."
                return reply
            }
            guard let text = envelope.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                reply.error = "Nothing to send."
                return reply
            }
            // Marked as another agent's, so it is not taken for the user's.
            let marked = "[Message from the Visor session “\(name)” (\(caller))\(computer.map { " on \($0)" } ?? ""), not from the user. "
                + "To answer, use send_message to that session.]\n\n" + text
            let busy = target.info.busy
            deliver(marked, to: target)
            let targetName = target.info.title.isEmpty ? target.info.agent.title : target.info.title
            reply.text = busy ? "Queued for \(targetName): it is working and takes it when its turn ends." : "Sent to \(targetName)."
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
