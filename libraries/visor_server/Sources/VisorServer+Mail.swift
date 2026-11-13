// Agents' inboxes and outboxes (docs/agent-mail.md). A message from one
// session to another goes into the other's inbox, and a copy into the
// sender's outbox. The other agent is not handed the message as a turn of
// the user's: it is told, in a turn of one line, how many messages wait
// unread, and reads them with read_inbox. A session whose agent may not
// have read_inbox yet (one a launch before this one started, still
// running under its host) is handed the message as before, headed with
// who sent it.

import Foundation
import VisorProtocol

extension VisorServer {
    /// A message for `target` from another session, here or (`computer`
    /// set) on another server, by `messageID` (the relay's, for a message
    /// carried here). Into the inbox when its agent reads mail, else as a
    /// turn headed with its sender. Whether the agent was working.
    /// `marked`: one the agent wrote as words (AgentMessageMarkers), handed
    /// over as a turn beginning `@@from`, never into the inbox.
    func mail(_ text: String, from sender: RelayEndpoint, to target: SessionRecord, messageID: String, here: Bool,
              marked: Bool = false) -> Bool {
        let now = Date().timeIntervalSince1970
        let to = RelayEndpoint(server: id, serverName: hostName, session: target.info.id, sessionName: target.displayName)
        let message = MailMessage(id: messageID, from: sender, to: to, text: text, sent: now, state: .delivered, changed: now)
        let busy = target.info.busy
        // The sender's copy, when the sender is here; one on another
        // server keeps its own.
        if here, let source = session(sender.session) { source.mailbox.send(message) }
        // A written message, or any message to a session run by a runner's
        // agent, which has none of Visor's tools (no inbox to read): handed
        // over as a turn beginning `@@from`, which it answers in kind.
        if marked || target.driven {
            let name = sender.sessionName.isEmpty ? sender.session : sender.sessionName
            deliver(AgentMessageMarkers.inboundText(from: name, on: sender.serverName, body: text), to: target)
        } else if target.takesMail {
            target.mailbox.receive(message)
            notifyMail(target)
        } else {
            deliver(Self.agentMessageHeader(from: sender, to: to) + "\n\n" + text, to: target)
        }
        saveArchive()
        broadcastSessionsSoon()
        return busy
    }

    /// The agent told how many messages wait unread. One notice waiting in
    /// its queue is enough: it counts what is unread when its turn comes
    /// (SessionRecord.takeNextQueued).
    func notifyMail(_ target: SessionRecord) {
        guard target.mailbox.unread > 0, !target.info.queued.contains(where: Mailbox.isNotice) else { return }
        deliver(Mailbox.notice(unread: target.mailbox.unread), to: target)
    }

    /// read_inbox: the inbox's messages, oldest first, each headed with who
    /// sent it and how to answer; those unread are marked read, and a
    /// sender here learns it in its outbox. `text` "all" asks for the read
    /// ones too; `rows`, how many (1 to 50, 10 by default).
    func readInbox(_ ask: Envelope, caller: SessionRecord) -> Envelope {
        var reply = Envelope(type: "agent_result")
        reply.id = ask.id
        let all = ask.text == "all"
        let now = Date().timeIntervalSince1970
        let read = caller.mailbox.read(unreadOnly: !all, count: max(1, min(ask.rows ?? 10, 50)), at: now)
        for message in read.messages where read.newlyRead.contains(message.id) {
            if isThisServer(message.from.server) {
                session(message.from.session)?.mailbox.update(sent: message.id, to: .read, at: now)
            } else {
                sendReadReceipt(for: message, at: now)
            }
        }
        if !read.newlyRead.isEmpty {
            saveArchive()
            broadcastSessionsSoon()
        }
        guard !read.messages.isEmpty else {
            reply.text = all ? "Your inbox is empty." : "No unread messages."
            return reply
        }
        let left = caller.mailbox.unread
        reply.text = read.messages.map { message in
            "Message \(message.id), sent \(Self.mailTime(message.sent)):\n"
                + Self.agentMessageHeader(from: message.from, to: message.to) + "\n\n" + message.text
        }.joined(separator: "\n\n---\n\n") + (left > 0 ? "\n\n(\(left) more unread: read_inbox again.)" : "")
        return reply
    }

    /// read_outbox: what this session sent, oldest first, and what became
    /// of each. `rows`, how many (1 to 50, 10 by default).
    func readOutbox(_ ask: Envelope, caller: SessionRecord) -> Envelope {
        var reply = Envelope(type: "agent_result")
        reply.id = ask.id
        let sent = caller.mailbox.outbox.suffix(max(1, min(ask.rows ?? 10, 50)))
        guard !sent.isEmpty else {
            reply.text = "Your outbox is empty."
            return reply
        }
        reply.text = sent.map { message in
            let to = "“\(message.to.sessionName.isEmpty ? message.to.session : message.to.sessionName)” (\(message.to.session)) on \(message.to.serverName)"
            let words = message.text.count > 300 ? String(message.text.prefix(300)) + "…" : message.text
            return "Message \(message.id) to \(to), sent \(Self.mailTime(message.sent)): \(Self.describe(message))\n\(words)"
        }.joined(separator: "\n\n")
        return reply
    }

    /// A message this session sent, by its id, as message_status tells it.
    func mailStatus(_ ask: Envelope, caller: SessionRecord) -> Envelope? {
        guard let key = ask.messageID, let message = caller.mailbox.outbox.last(where: { $0.id == key }) else { return nil }
        var reply = Envelope(type: "agent_result")
        reply.id = ask.id
        reply.messageID = key
        let to = "“\(message.to.sessionName.isEmpty ? message.to.session : message.to.sessionName)” (\(message.to.session)) on \(message.to.serverName)"
        reply.text = "Message \(message.id) to \(to): \(Self.describe(message))"
        return reply
    }

    /// What became of a message sent elsewhere, from the relay, in the
    /// sender's outbox.
    func noteMailOutcome(_ record: RelayRecord) {
        guard record.message.kind == .send, let source = session(record.message.from.session) else { return }
        let state: MailMessage.State? = switch record.status {
        case .waiting: nil
        case .sent, .queued: .delivered
        case .read: .read
        case .failed: .failed
        case .expired: .expired
        }
        guard let state else { return }
        if source.mailbox.update(sent: record.message.id, to: state, problem: state == .failed ? record.result : nil, at: record.updated) {
            saveArchive()
            broadcastSessionsSoon()
        }
    }

    /// Word to a message's sender on another server that it was read, as a
    /// relay message of its own (`receipt`), carried as any other. Only to
    /// a server reported at 0.47 or later, which knows one.
    func sendReadReceipt(for message: MailMessage, at now: Double) {
        guard let server = reportedServers().first(where: { $0.server.id == message.from.server })?.server,
              Self.knowsReceipts(server.version) else { return }
        enqueueRelay(RelayMessage(id: UUID().uuidString.lowercased(), kind: .receipt, from: message.to, to: message.from,
                                  text: message.id, created: now, expires: now + Self.relayLifetime))
    }

    /// A read receipt carried here: the message it names read, in the
    /// outbox of the session that sent it.
    func takeReadReceipt(_ receipt: RelayMessage) -> RelayReceipt {
        guard let sender = session(receipt.to.session) else {
            return RelayReceipt(message: receipt.id, outcome: .failed, text: "No session \(receipt.to.session) here.")
        }
        if sender.mailbox.update(sent: receipt.text, to: .read, at: receipt.created) {
            saveArchive()
            broadcastSessionsSoon()
        }
        return RelayReceipt(message: receipt.id, outcome: .sent, text: "")
    }

    /// Whether a server of this version (MAJOR.MINOR.BUILD) takes read
    /// receipts: 0.47 and later.
    static func knowsReceipts(_ version: String?) -> Bool {
        let parts = (version ?? "").split(separator: ".").compactMap { Int($0.prefix { $0.isNumber }) }
        guard parts.count >= 2 else { return false }
        return parts[0] > 0 || parts[1] >= 47
    }

    private static func describe(_ message: MailMessage) -> String {
        switch message.state {
        case .waiting: "waiting for a Visor client connected to both computers to carry it"
        case .delivered: "in their inbox, unread"
        case .read: "read"
        case .failed: "not taken" + (message.problem.map { ": \($0)" } ?? "")
        case .expired: "expired: no Visor client carried it within a day"
        }
    }

    private static func mailTime(_ seconds: Double) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
    }
}
