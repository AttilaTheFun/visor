// Agents' messages written as words (AgentMessageMarkers; Logan, 12 Nov
// 2026): a reply of an agent's that begins `@@to <session> on <computer>`
// is a message to that session. One to a session here is handed over at
// once, as a turn beginning `@@from`; one to another computer waits in the
// relay's outbox, its computer and session by name until a client's report
// names them (its ids then filled in), and is carried there by a client as
// any relayed message is. It waits until it is taken: it doesn't expire.
// Each is in the sender's outbox, so its fate is shown as the inbox's
// messages' is. The inbox's tools (send_message, read_inbox) work on
// beside this until every client and session has moved over.

import Foundation
import VisorProtocol

extension VisorServer {
    /// How long a written message waits to be taken: as good as for ever
    /// (Logan: until it is received, or the person trashes it).
    static let markedLifetime: TimeInterval = 10 * 365 * 24 * 60 * 60

    /// The messages in `record`'s last turn: each sent once, by the id of
    /// its row.
    func sendMarkedMessages(of record: SessionRecord) {
        sendMarkedMessages(in: Array(record.entries.reversed().prefix { $0.role != .user }.reversed()), of: record)
    }

    /// The messages among `rows`, each sent once, by the id of its row: a
    /// turn's when it ends, and a native agent's rows as they are read from
    /// its file, which can come after its turn's end is heard (13 Nov: a
    /// message written last in a turn never went).
    func sendMarkedMessages(in rows: [TranscriptEntry], of record: SessionRecord) {
        for entry in rows where entry.role == .assistant {
            guard let addressed = AgentMessageMarkers.outbound(entry.text) else { continue }
            let messageID = "\(record.info.id)-\(entry.id)"
            guard !record.mailbox.outbox.contains(where: { $0.id == messageID }) else { continue }
            sendMarked(addressed, from: record, messageID: messageID)
        }
    }

    /// One message: to a session here at once; to another computer through
    /// the relay; to a session here that isn't, failed in the outbox.
    func sendMarked(_ addressed: AgentMessageMarkers.Addressed, from record: SessionRecord, messageID: String) {
        let now = Date().timeIntervalSince1970
        let from = RelayEndpoint(server: id, serverName: hostName, session: record.info.id, sessionName: record.displayName)
        if isThisServer(addressed.computer) {
            guard let target = markedTarget(named: addressed.session, except: record) else {
                let to = RelayEndpoint(server: id, serverName: hostName, session: "", sessionName: addressed.session)
                record.mailbox.send(MailMessage(id: messageID, from: from, to: to, text: addressed.body, sent: now, state: .failed,
                                                changed: now, problem: "No session named “\(addressed.session)” on \(hostName)."))
                saveArchive()
                broadcastSessionsSoon()
                return
            }
            _ = mail(addressed.body, from: from, to: target, messageID: messageID, here: true, marked: true)
            return
        }
        let to = RelayEndpoint(server: "", serverName: addressed.computer, session: "", sessionName: addressed.session)
        record.mailbox.send(MailMessage(id: messageID, from: from, to: to, text: addressed.body, sent: now, state: .waiting, changed: now))
        enqueueRelay(RelayMessage(id: messageID, kind: .send, from: from, to: to, text: addressed.body, created: now,
                                  expires: now + Self.markedLifetime, marked: true))
        saveArchive()
        broadcastSessionsSoon()
    }

    /// A session of this server's that a message names: by its name or its
    /// id, ignoring case; not the sender, and not ended or archived.
    func markedTarget(named name: String, except sender: SessionRecord?) -> SessionRecord? {
        sessions.first { record in
            record !== sender && !record.info.ended && !record.info.archived
                && (Self.sameName(record.displayName, name) || record.info.id == name)
        }
    }

    /// The written messages waiting for a computer and session by name,
    /// given their ids where a client's report names them. One whose
    /// computer is reported but not its session waits on: it may appear.
    func resolveMarked(by report: DirectoryReport) {
        var changed = false
        for (key, record) in relayOutbox where record.status == .waiting && record.message.to.server.isEmpty {
            let to = record.message.to
            guard let server = report.servers.first(where: { $0.id != id && Self.sameName($0.name, to.serverName) }),
                  let session = server.sessions.first(where: { Self.sameName($0.name, to.sessionName) || $0.id == to.sessionName })
            else { continue }
            relayOutbox[key]?.message.to = RelayEndpoint(server: server.id, serverName: server.name, session: session.id, sessionName: session.name)
            changed = true
        }
        if changed { keepRelayOutbox() }
    }

    /// A written message carried here: handed to its session as a turn
    /// beginning `@@from`.
    func takeMarked(_ message: RelayMessage) -> RelayReceipt {
        guard let target = markedTarget(named: message.to.session, except: nil) else {
            return RelayReceipt(message: message.id, outcome: .failed, text: "No session “\(message.to.sessionName)” on \(hostName).")
        }
        let busy = mail(message.text, from: message.from, to: target, messageID: message.id, here: false, marked: true)
        return RelayReceipt(message: message.id, outcome: busy ? .queued : .sent, text: "")
    }
}
