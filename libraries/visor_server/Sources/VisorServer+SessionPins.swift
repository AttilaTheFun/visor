// A session pinned to the top of its computer's list, or unpinned (`pin`,
// `unpin`): the session's own, kept with it in sessions.json and told to
// every client, so each device lists the same. Its `pinnedAt` orders the
// pinned ones, the first pinned on top: a pin goes after every other on
// the computer, so an unpin and a pin again moves a session to the last
// of them. An archived session isn't pinned: archiving takes its pin
// (VisorServer+Agents), and a pin asked of one is passed over.

import Foundation
import VisorProtocol

extension VisorServer {
    func performPin(_ envelope: Envelope, pinned: Bool) {
        guard let record = session(envelope.session) else { return }
        // Pinned already, or unpinned already: where it is it stays.
        guard (record.info.pinnedAt != nil) != pinned, !(pinned && record.info.archived) else {
            broadcastSessions()
            return
        }
        record.info.pinnedAt = pinned ? nextPin() : nil
        Self.log("\(record.info.title): \(pinned ? "pinned" : "unpinned")")
        saveArchive()
        broadcastSessions()
    }

    /// When a pin made now is: the clock, or just after the latest pin on
    /// the computer when the clock isn't past it (two in the same moment,
    /// or a clock set back), so the newest pin is always the last.
    func nextPin(now: Double = Date().timeIntervalSince1970) -> Double {
        let latest = sessions.compactMap(\.info.pinnedAt).max() ?? 0
        return max(now, latest + 0.001)
    }
}
