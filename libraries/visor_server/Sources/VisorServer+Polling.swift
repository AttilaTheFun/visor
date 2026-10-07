// What a client gets without the live channel: the list of sessions and a
// session's ephemeral state (what streams, the turn's status, busy, an
// approval waiting, the queue, a notice), each held until it changes, as
// the transcript's sync is. The socket is the quick way to hear these;
// over a path that carries no WebSocket (a proxy that does not pass them,
// a network that drops them) the same arrives by asking again, and the
// client works. Terminal bytes are the one thing only the channel carries.

import Foundation
import VisorProtocol

extension VisorServer {
    /// How long a poll is held before it is answered with nothing new.
    static let pollHold: TimeInterval = 25

    // MARK: The list of sessions

    /// The sessions and the catalogs, as `welcome` carries them, with the
    /// list's revision.
    func sessionsEnvelope() -> Envelope {
        var e = Envelope.welcome(host: hostName, sessions: sessions.map(\.info), catalogs: catalogs())
        e.revision = sessionsRevision
        return e
    }

    /// The list changed: counted, and everyone holding for it is answered.
    func sessionsChanged() {
        sessionsRevision += 1
        let waiting = sessionsWaiters
        sessionsWaiters = []
        let answer = HTTPResponse.json(sessionsEnvelope().encoded())
        for respond in waiting { respond(answer) }
    }

    /// `GET /sessions?since=<revision>`: answered when the list is past
    /// that revision, held until it is (or for a while).
    func answerSessions(since: Int?, respond: @escaping (HTTPResponse) -> Void) {
        guard let since, since == sessionsRevision else { return respond(.json(sessionsEnvelope().encoded())) }
        sessionsWaiters.append(respond)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pollHold))
            guard let self else { return }
            // Still held after the hold: answered with what there is.
            if !self.sessionsWaiters.isEmpty { self.sessionsChanged() }
        }
    }

    // MARK: A session's state

    /// Something ephemeral about a session was told to its subscribers:
    /// those polling for it hear the same.
    func stateChanged(_ record: SessionRecord) {
        record.stateRevision += 1
        guard let waiting = stateWaiters.removeValue(forKey: record.info.id), !waiting.isEmpty else { return }
        let answer = HTTPResponse.json(stateEnvelope(record).encoded())
        for respond in waiting { respond(answer) }
    }

    func stateEnvelope(_ record: SessionRecord) -> Envelope {
        var e = record.ephemeralEnvelope
        e.revision = record.stateRevision
        return e
    }

    /// `GET /sessions/<id>/state?since=<revision>`: the session's ephemeral
    /// state once it is past that revision. Asking is also following the
    /// session: its file is read as a subscriber's would be.
    func answerState(of record: SessionRecord, since: Int?, respond: @escaping (HTTPResponse) -> Void) {
        if !record.isBound { bind(record) }
        record.followFileIfNeeded()
        guard let since, since == record.stateRevision else { return respond(.json(stateEnvelope(record).encoded())) }
        stateWaiters[record.info.id, default: []].append(respond)
        Task { [weak self, weak record] in
            try? await Task.sleep(for: .seconds(Self.pollHold))
            guard let self, let record, let waiting = self.stateWaiters.removeValue(forKey: record.info.id) else { return }
            let answer = HTTPResponse.json(self.stateEnvelope(record).encoded())
            for respond in waiting { respond(answer) }
        }
    }

    /// `GET /sessions/<id>/earlier?before=<row>`: the rows before one.
    func answerEarlier(of record: SessionRecord, before: String, respond: @escaping (HTTPResponse) -> Void) {
        Task { respond(.json(await record.earlier(before: before).encoded())) }
    }

    /// A session that is gone answers no more polls.
    func dropWaiters(for id: String) {
        transcriptWaiters.removeValue(forKey: id)?.forEach { $0.respond(HTTPResponse(404, "{\"error\":\"no such session\"}")) }
        stateWaiters.removeValue(forKey: id)?.forEach { $0(HTTPResponse(404, "{\"error\":\"no such session\"}")) }
    }
}
