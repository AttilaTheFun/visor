// Messages from agents on other servers, carried here by a client
// connected to both (`POST /api/relay/deliver`): each taken once, however
// many clients carry it and however often — the ledger keeps what became
// of each by its id, and a message carried again is answered from it —
// and sent or read as this server's own agents' asks are, marked with who
// sent it and how to answer.

import Foundation
import VisorProtocol

extension VisorServer {
    /// How long what became of a carried message is kept: past its
    /// sender's outbox keeping it, so no copy of it can still come.
    static let relayLedgerKept: TimeInterval = 2 * relayLifetime

    static var relayLedgerURL: URL { storeURL.deletingLastPathComponent().appendingPathComponent("relay-ledger.json", isDirectory: false) }

    static func keptRelayLedger() -> [String: RelayLedgerEntry] {
        guard let data = try? Data(contentsOf: relayLedgerURL) else { return [:] }
        return (try? JSONDecoder().decode([String: RelayLedgerEntry].self, from: data)) ?? [:]
    }

    func keepRelayLedger() {
        if let data = try? JSONEncoder().encode(relayLedger) { try? data.write(to: Self.relayLedgerURL, options: .atomic) }
    }

    /// What became of a message carried here, taken now or before. Nil for
    /// one that is for another server.
    func takeRelayed(_ message: RelayMessage, now: Double = Date().timeIntervalSince1970) -> RelayReceipt? {
        guard message.to.server == id else { return nil }
        relayLedger = relayLedger.filter { now - $0.value.at < Self.relayLedgerKept }
        if let taken = relayLedger[message.id] { return taken.receipt }
        let receipt = message.expires <= now
            ? RelayReceipt(message: message.id, outcome: .failed, text: "It expired before it was carried here.")
            : perform(message)
        relayLedger[message.id] = RelayLedgerEntry(receipt: receipt, at: now)
        keepRelayLedger()
        return receipt
    }

    /// The message sent or read here, as an agent of this server would.
    private func perform(_ message: RelayMessage) -> RelayReceipt {
        var ask = Envelope(type: "agent")
        ask.mode = message.kind.rawValue
        ask.session = message.to.session
        ask.text = message.text
        ask.rows = message.rows
        let reply = answer(ask, from: message.from.session, named: message.from.sessionName, on: message.from)
        if let error = reply.error { return RelayReceipt(message: message.id, outcome: .failed, text: error) }
        let outcome: RelayReceipt.Outcome = message.kind == .read ? .read : reply.busy == true ? .queued : .sent
        return RelayReceipt(message: message.id, outcome: outcome, text: message.kind == .read ? reply.text ?? "" : "")
    }
}
