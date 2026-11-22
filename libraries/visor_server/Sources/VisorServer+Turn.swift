// A session's turn state (TurnState: sending, thinking, responding, waiting
// on something, idle), told whenever it changes: to the session's
// subscribers as `turn`, to those polling with the state, and to every
// client with the sessions list (`SessionInfo.turn`), for the line under a
// session at work. It changes a few times a turn, not with every piece of
// the reply: streamed words move it to `responding` once.

import VisorProtocol

extension VisorServer {
    /// Tells the session's turn state if it changed since it was last told;
    /// the list, a moment later, unless it is being sent now (`listed`).
    func tellTurn(_ record: SessionRecord, listed: Bool = false) {
        let now = record.currentTurn
        guard now != record.toldTurn else { return }
        record.toldTurn = now
        record.info.turn = now.isIdle ? nil : now
        broadcast(.turn(session: record.info.id, now), session: record)
        if !listed { broadcastSessionsSoon() }
    }
}
