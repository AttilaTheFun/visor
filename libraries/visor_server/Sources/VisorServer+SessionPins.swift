// A session pinned to the top of its computer's list, or unpinned (`pin`,
// `unpin`): the session's own, kept in its row of the sessions' store
// (server.sqlite: SessionStore's `pinned`), and told to every client, so
// each device lists the same. Pinned or not is all there is: a list sorts
// its pinned by title. An archived session isn't pinned: archiving takes
// its pin, and a pin asked of one is passed over; a session ended takes
// its pin with its row.

import VisorProtocol

extension VisorServer {
    func performPin(_ envelope: Envelope, pinned: Bool) {
        guard let record = session(envelope.session) else { return }
        guard record.info.pinned != pinned, !(pinned && record.info.archived) else {
            broadcastSessions()
            return
        }
        setPinned(pinned, record)
        Self.log("\(record.info.title): \(pinned ? "pinned" : "unpinned")")
        broadcastSessions()
    }

    /// The pin in the session's info, and written down at once.
    func setPinned(_ pinned: Bool, _ record: SessionRecord) {
        record.info.pinned = pinned
        saveArchiveNow()
    }
}
