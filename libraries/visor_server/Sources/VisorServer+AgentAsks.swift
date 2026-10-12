// What an agent asks of the other sessions, through the Visor MCP server
// it runs (VisorMCPScript.swift): the sessions here and on the servers
// the clients report (VisorServer+Directory.swift), a message to one or
// its latest rows, and what became of a message sent elsewhere. Asks of
// this server's own sessions are answered at once
// (VisorServer+Messages.swift); one for another server's goes into the
// relay outbox (VisorServer+RelayOutbox.swift) and is answered when a
// client has carried it, or after a while with how to ask after it.

import Foundation
import VisorProtocol

/// Where an agent's ask goes.
private enum AskDestination {
    case here
    case there(DirectoryServer, DirectorySession)
    case nowhere(String)
}

extension VisorServer {
    /// How long a send waits to be carried before the agent is told it
    /// waits; a read, which needs what it finds, waits longer.
    static var relaySendWait: TimeInterval = 8
    static var relayReadWait: TimeInterval = 20

    /// What an agent asked, answered: `mode` is the ask, `client` the
    /// asking session, `session` (and `server`) the one it is about,
    /// `messageID` the message a status is asked of.
    func answerAgent(_ envelope: Envelope, reply: @escaping (Envelope) -> Void) {
        guard envelope.token == agentToken, let caller = session(envelope.client) else {
            return reply(agentReply(envelope))
        }
        switch envelope.mode {
        case "sessions": reply(listSessions(for: envelope, caller: caller))
        case "send", "read": route(envelope, from: caller, reply: reply)
        case "status": reply(relayStatus(envelope))
        default: reply(agentReply(envelope))
        }
    }

    /// The other sessions here, then each reported server's.
    private func listSessions(for envelope: Envelope, caller: SessionRecord) -> Envelope {
        var reply = agentReply(envelope)
        let here = reply.text ?? ""
        var sections = ["On this computer, \(hostName) (server \(id)):\n" + (here == "No other sessions." ? "No other sessions." : here)]
        let now = Date()
        for reported in reportedServers(now: now) {
            let ago = Int(now.timeIntervalSince(reported.at))
            let heading = "On \(reported.server.name) (server \(reported.server.id)), as \(reported.by) reported \(ago) s ago:"
            let lines = reported.server.sessions.map { session in
                "\(session.id) — \(session.name)" + (session.agent.isEmpty ? "" : " (\(session.agent), \(session.busy ? "working" : "idle"))")
            }
            sections.append(heading + "\n" + (lines.isEmpty ? "No sessions." : lines.joined(separator: "\n")))
        }
        if sections.count > 1 {
            sections.append("A session on another computer is reached through a Visor client connected to both: give send_message or read_messages its id, and its server's id when two computers have a session of that id.")
        }
        reply.text = sections.joined(separator: "\n\n")
        return reply
    }

    /// A send or a read, here or into the outbox.
    private func route(_ envelope: Envelope, from caller: SessionRecord, reply: @escaping (Envelope) -> Void) {
        var ask = envelope
        // Before ids, a session elsewhere was written `<computer>/<id>`.
        if (ask.server ?? "").isEmpty, let target = ask.session, let slash = target.lastIndex(of: "/") {
            ask.server = String(target[..<slash])
            ask.session = String(target[target.index(after: slash)...])
        }
        switch destination(of: ask, caller: caller) {
        case .here: reply(agentReply(ask))
        case .there(let server, let session): relay(ask, from: caller, to: server, session, reply: reply)
        case .nowhere(let problem): reply(agentError(problem, to: ask))
        }
    }

    private func destination(of ask: Envelope, caller: SessionRecord) -> AskDestination {
        let session = ask.session ?? ""
        let server = (ask.server ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !server.isEmpty {
            if isThisServer(server) { return .here }
            let matches = reportedServers(matching: server)
            if matches.count > 1 {
                return .nowhere("Several computers are named \(server): give the server's id — " + matches.map(\.id).joined(separator: ", ") + ".")
            }
            guard let match = matches.first else {
                return .nowhere("No computer \(server) is known here. A computer is known once a Visor client connected to both reports it; list_sessions names those reported.")
            }
            guard let target = match.sessions.first(where: { $0.id == session }) else {
                return .nowhere("No session \(session) on \(match.name), as last reported; list_sessions names them.")
            }
            return .there(match, target)
        }
        // A session id alone: this server's, or the one reported server's
        // that has it.
        if sessions.contains(where: { $0.info.id == session && $0 !== caller }) { return .here }
        let elsewhere = reportedSessions(withID: session)
        if elsewhere.count > 1 {
            return .nowhere("Several computers have a session \(session): give the server's id too — " + elsewhere.map(\.server.id).joined(separator: ", ") + ".")
        }
        guard let found = elsewhere.first else { return .here }
        return .there(found.server, found.session)
    }

    /// A message for another server into the outbox, answered once a
    /// client has carried it or after a while.
    private func relay(_ ask: Envelope, from caller: SessionRecord, to server: DirectoryServer, _ session: DirectorySession,
                       reply: @escaping (Envelope) -> Void) {
        let kind: RelayMessage.Kind = ask.mode == "read" ? .read : .send
        let text = (ask.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .send, text.isEmpty { return reply(agentError("Nothing to send.", to: ask)) }
        let now = Date().timeIntervalSince1970
        let message = RelayMessage(id: UUID().uuidString.lowercased(), kind: kind,
                                   from: RelayEndpoint(server: id, serverName: hostName, session: caller.info.id, sessionName: caller.displayName),
                                   to: RelayEndpoint(server: server.id, serverName: server.name, session: session.id, sessionName: session.name),
                                   text: text, rows: max(1, min(ask.rows ?? 10, 50)), created: now, expires: now + Self.relayLifetime)
        enqueueRelay(message)
        awaitRelay(message.id, for: kind == .read ? Self.relayReadWait : Self.relaySendWait) { [weak self] record in
            guard let self else { return }
            reply(self.agentResult(record, to: ask, asStatus: false))
        }
    }

    /// What became of a message sent elsewhere, by its id.
    private func relayStatus(_ ask: Envelope) -> Envelope {
        ageRelayOutbox()
        guard let key = ask.messageID, let record = relayOutbox[key] else {
            return agentError("No message with that id was sent from here in the last day.", to: ask)
        }
        return agentResult(record, to: ask, asStatus: true)
    }

    /// A relayed message's record, as the agent reads it: a read's rows,
    /// or where the message is.
    private func agentResult(_ record: RelayRecord, to ask: Envelope, asStatus: Bool) -> Envelope {
        let message = record.message
        let target = "“\(message.to.sessionName.isEmpty ? message.to.session : message.to.sessionName)” on \(message.to.serverName)"
        var reply = Envelope(type: "agent_result")
        reply.id = ask.id
        reply.messageID = message.id
        switch record.status {
        case .waiting:
            reply.text = "Waiting: no Visor client connected to both this computer and \(message.to.serverName) has carried it to \(target) yet. "
                + "It is kept for a day; message_status with message id \(message.id) tells what becomes of it."
        case .sent: reply.text = "Sent to \(target)."
        case .queued: reply.text = "Queued for \(target): it is working and takes it when its turn ends."
        case .read: reply.text = asStatus ? "Read from \(target):\n\n" + record.result : record.result
        case .failed: reply.error = "Not taken on \(message.to.serverName): \(record.result)"
        case .expired: reply.error = "Expired: no Visor client connected to both computers carried it to \(target) within a day."
        }
        return reply
    }

    private func agentError(_ problem: String, to ask: Envelope) -> Envelope {
        var reply = Envelope(type: "agent_result")
        reply.id = ask.id
        reply.error = problem
        return reply
    }
}
