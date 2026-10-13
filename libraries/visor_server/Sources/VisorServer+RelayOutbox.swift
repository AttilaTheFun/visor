// What the agents here send to sessions on other servers: each message
// kept in the outbox until a client connected to both carries it there
// and brings back what became of it (VisorServer+RelayDelivery.swift), or
// until a day has passed. Kept on disk, so a restart loses none; one
// finished is kept a day more, for its sender to ask after.

import Foundation
import VisorProtocol

extension VisorServer {
    /// How long a message waits for a client to carry it.
    static let relayLifetime: TimeInterval = 24 * 60 * 60

    static var relayOutboxURL: URL { storeURL.deletingLastPathComponent().appendingPathComponent("relay-outbox.json", isDirectory: false) }

    static func keptRelayOutbox() -> [String: RelayRecord] {
        guard let data = try? Data(contentsOf: relayOutboxURL),
              let records = try? JSONDecoder().decode([RelayRecord].self, from: data) else { return [:] }
        return Dictionary(records.map { ($0.message.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func keepRelayOutbox() {
        let records = relayOutbox.values.sorted { $0.message.created < $1.message.created }
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: Self.relayOutboxURL, options: .atomic) }
    }

    /// A message into the outbox, and the clients on the live channel told
    /// to come for it now rather than at their next report.
    func enqueueRelay(_ message: RelayMessage) {
        relayOutbox[message.id] = RelayRecord(message: message, status: .waiting, result: "", updated: Date().timeIntervalSince1970)
        keepRelayOutbox()
        let nudge = Envelope(type: "relay")
        for connection in connections.values where connection.authenticated { connection.send(nudge) }
    }

    /// The messages waiting for the servers a client reports: what it is
    /// to carry.
    func relayedMessages(for report: DirectoryReport) -> [RelayMessage] {
        ageRelayOutbox()
        let reached = Set(report.servers.map(\.id)).subtracting([id])
        return relayOutbox.values.filter { $0.status == .waiting && reached.contains($0.message.to.server) }
            .map(\.message).sorted { $0.created < $1.created }
    }

    /// What became of a message where it went, from the client that
    /// carried it: the first word is kept, any after it (a second client
    /// that carried it too) changes nothing. Whether it was news.
    @discardableResult
    func takeReceipt(_ receipt: RelayReceipt) -> Bool {
        guard var record = relayOutbox[receipt.message], record.status == .waiting else { return false }
        record.status = switch receipt.outcome {
        case .sent: .sent
        case .queued: .queued
        case .read: .read
        case .failed: .failed
        }
        record.result = receipt.text
        record.updated = Date().timeIntervalSince1970
        relayOutbox[receipt.message] = record
        keepRelayOutbox()
        tellRelayWaiters(record)
        return true
    }

    /// A waiting message past its time expires; a finished one a day old
    /// is dropped.
    func ageRelayOutbox(now: Double = Date().timeIntervalSince1970) {
        var changed = false
        for (key, record) in relayOutbox {
            if record.status == .waiting, record.message.expires <= now {
                relayOutbox[key]?.status = .expired
                relayOutbox[key]?.updated = now
                changed = true
            } else if record.status != .waiting, now - record.updated > Self.relayLifetime {
                relayOutbox[key] = nil
                changed = true
            }
        }
        if changed { keepRelayOutbox() }
    }

    /// Waits for a message's receipt, at most `seconds`: `answer` is told
    /// the record as it is then, carried or not.
    func awaitRelay(_ messageID: String, for seconds: TimeInterval, answer: @escaping (RelayRecord) -> Void) {
        let waiter = UUID().uuidString
        relayWaiters[messageID, default: [:]][waiter] = answer
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, let answer = self.relayWaiters[messageID]?.removeValue(forKey: waiter) else { return }
            if self.relayWaiters[messageID]?.isEmpty == true { self.relayWaiters[messageID] = nil }
            if let record = self.relayOutbox[messageID] { answer(record) }
        }
    }

    private func tellRelayWaiters(_ record: RelayRecord) {
        guard let waiting = relayWaiters.removeValue(forKey: record.message.id) else { return }
        for answer in waiting.values { answer(record) }
    }
}
