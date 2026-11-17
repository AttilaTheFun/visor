// A session's notifications switched on or off (`notifications`): the
// session's own, kept with it in sessions.json and told to every client,
// so each device shows the same switch. Off, nothing it does is pushed
// but the widget's silent state (VisorServer+Push), and clients make no
// notifications of their own for it.

import VisorProtocol

extension VisorServer {
    func performNotifications(_ envelope: Envelope) {
        guard let record = session(envelope.session), let on = envelope.on else { return }
        guard record.info.notifications != on else {
            broadcastSessions()
            return
        }
        record.info.notifications = on
        Self.log("\(record.info.title): notifications \(on ? "on" : "off")")
        saveArchive()
        broadcastSessions()
    }
}
