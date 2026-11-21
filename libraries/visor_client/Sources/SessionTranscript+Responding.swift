// The reply being written ("responding"): the agent's words as they
// stream (`delta`, and `ephemeral.streams` on subscribing or from
// `GET /state`), drawn as the agent's row until the record's own row for
// the message is synced, then that row in its place.
//
// The join, with the rows this client has synced (not the server's):
// - a stream of message M is drawn while the rows hold no assistant row
//   M or M#k, under the display id M, which the record's row then takes:
//   the thread sees one row change, never two rows or none;
// - it goes only when the rows hold it: never because the turn ended
//   (`busy` false) or the message did (`streamEnd`), which leave it drawn
//   until the sync brings the row;
// - one whose row never comes (a turn cut short, a server restarted) goes
//   once the next turn has begun and a sync has answered without it;
// - the thread's order: the record's rows, a reply of a turn that has
//   ended (it answers what came before), the user's rows not on the
//   record yet, the reply of the turn running; the queue is the
//   composer's.
//
// Views are told of the words on a cadence of their own, at most once a
// `respondingFrame` (a quarter second): the transcript's frame, a second,
// is too slow for words as they come. Nothing else is told then: the
// rows, and a stream's leaving as its row lands, go with the transcript's
// frame (`changed`). Whichever comes first, a view reads both as they are.

import VisorProtocol

extension SessionTranscript {
    /// A reply being written: its message id and its words so far.
    public struct Responding: Equatable, Sendable {
        public let id: String
        public internal(set) var text: String
        /// No more words come for it (`streamEnd`, the turn's end, or a
        /// snapshot without it): it waits for its row.
        var finished = false
        /// The turn it was written in has ended: drawn before the user's
        /// rows that are not on the record yet, which are the next turn's.
        var turnEnded = false
        /// A turn began after its own ended: gone at the next sync that
        /// does not bring its row.
        var superseded = false
    }

    /// The replies being written, as the thread draws them: those whose
    /// turn has ended (`ofEndedTurn`), which go before the user's rows not
    /// on the record yet, or those of the turn running, which go after
    /// them. Each is an assistant row under its message's id, the id its
    /// row on the record is shown under when it lands.
    public func responding(ofEndedTurn: Bool) -> [TranscriptEntry] {
        _ = respondingTick
        return respondingRows(ofEndedTurn: ofEndedTurn)
    }

    /// Words are the last thing the agent did (no thinking or tool since),
    /// and the reply they are in is still being written: the status line
    /// says "Writing…".
    public var writing: Bool {
        _ = respondingTick
        return writingNow && _responding.last.map { !$0.finished && !carried($0.id) } == true
    }

    /// The replies held, for tests.
    var respondingHeld: [Responding] { _responding }

    func respondingRows(ofEndedTurn: Bool) -> [TranscriptEntry] {
        _responding.compactMap { stream in
            guard stream.turnEnded == ofEndedTurn, !stream.text.isEmpty, !carried(stream.id) else { return nil }
            return TranscriptEntry(id: stream.id, role: .assistant, text: stream.text)
        }
    }

    /// Whether the rows held carry message `id` (`carries`). From the
    /// end, where a reply's row lands.
    func carried(_ id: String) -> Bool { _entries.last { Self.carries($0, id) } != nil }

    /// More words of message `id`, going where `from` says (the UTF-8
    /// length of the words before them; nil from a server before 0.64,
    /// whose words are appended). None for a message the rows already
    /// hold: its row is the reply. Words held already (a snapshot brought
    /// them first) are passed over; words that don't meet what is held
    /// (some were missed) are not taken, and the state is asked for again,
    /// once until it comes: its snapshot puts the words right.
    func takeDelta(id: String, text: String, from: Int? = nil) {
        guard !carried(id) else { return }
        if let from {
            let held = _responding.first { $0.id == id }?.text.utf8.count ?? 0
            if from != held {
                guard from + text.utf8.count > held else { return }
                if !stateAsked {
                    stateAsked = true
                    askState?()
                }
                return
            }
        }
        if let index = _responding.firstIndex(where: { $0.id == id }) {
            _responding[index].text += text
        } else {
            _responding.append(Responding(id: id, text: text))
        }
        writingNow = true
        respondingChanged()
    }

    /// What the server has unrecorded now (on subscribing, or polled): each
    /// one's words are the snapshot's, in place of what was held. One held
    /// and not in it was recorded there, or lost with a restart: it is
    /// kept, finished, until the rows bring it or a new turn clears it.
    func takeStreams(_ streams: [StreamChunk]) {
        stateAsked = false
        let before = _responding
        let given = Dictionary(streams.map { ($0.id, $0.text) }, uniquingKeysWith: { $1 })
        for index in _responding.indices {
            if let text = given[_responding[index].id] {
                _responding[index].text = text
            } else {
                _responding[index].finished = true
                if !_busy { _responding[index].turnEnded = true }
            }
        }
        let held = Set(_responding.map(\.id))
        for stream in streams where !held.contains(stream.id) && !carried(stream.id) {
            _responding.append(Responding(id: stream.id, text: stream.text, turnEnded: !_busy))
        }
        writingNow = _busy && _responding.last.map { given[$0.id] != nil } == true
        if _responding != before { respondingChanged() }
    }

    /// The message `id` is written (`streamEnd`): drawn until its row is
    /// synced all the same.
    func endStream(id: String?) {
        guard let id, let index = _responding.firstIndex(where: { $0.id == id }) else { return }
        _responding[index].finished = true
        if index == _responding.index(before: _responding.endIndex) { writingNow = false }
        respondingChanged()
    }

    /// The session's turn started or ended, as the server says. Its end
    /// finishes what was being written; a new one supersedes what was
    /// written before it.
    func takeBusy(_ now: Bool) {
        let was = _busy
        busy = now
        if !now {
            writingNow = false
            guard _responding.contains(where: { !$0.turnEnded || !$0.finished }) else { return }
            for index in _responding.indices {
                _responding[index].finished = true
                _responding[index].turnEnded = true
            }
            respondingChanged()
        } else if !was {
            // What a turn before this one wrote and no row has carried
            // goes at the next sync that does not bring it either.
            for index in _responding.indices where _responding[index].turnEnded {
                _responding[index].superseded = true
            }
        }
    }

    /// After a sync: the replies the rows now hold go, each row shown under
    /// its message's id; and what an earlier turn left with no row.
    /// Told with the rows (the sync's `changed`), in the same pass.
    func settleResponding() {
        guard !_responding.isEmpty else { return }
        _responding.removeAll { stream in
            // The first row of the message takes the stream's place, under
            // the message's id: the row's own, but for a segment's suffix.
            if let first = _entries.first(where: { Self.carries($0, stream.id) }) {
                if first.id != stream.id, displayIDs[first.id] == nil { displayIDs[first.id] = stream.id }
                return true
            }
            return stream.superseded
        }
    }

    /// Whether a row is message `id`'s: an assistant row with its id, or
    /// that id with a segment's suffix.
    static func carries(_ row: TranscriptEntry, _ id: String) -> Bool {
        row.role == .assistant && (row.id == id || row.id.hasPrefix(id + "#"))
    }

    /// Nothing held: the session was let go of.
    func clearResponding() {
        respondingFrameEnds?.cancel()
        respondingFrameEnds = nil
        respondingFraming = false
        respondingDirty = false
        writingNow = false
        stateAsked = false
        guard !_responding.isEmpty else { return }
        _responding = []
        tellResponding()
    }

    /// The words changed: told now after a quiet frame, else at the
    /// frame's end, with whatever else came in it.
    func respondingChanged() {
        if respondingFraming {
            respondingDirty = true
            return
        }
        tellResponding()
        startRespondingFrame()
    }

    func tellResponding() {
        respondingDirty = false
        respondingAnnounced += 1
        respondingTick &+= 1
    }

    private func startRespondingFrame() {
        respondingFraming = true
        respondingFrameEnds?.cancel()
        respondingFrameEnds = Task { [weak self] in
            try? await Task.sleep(nanoseconds: SessionTranscript.respondingFrame)
            guard !Task.isCancelled, let self else { return }
            if self.respondingDirty {
                self.tellResponding()
                self.startRespondingFrame()
            } else {
                self.respondingFraming = false
            }
        }
    }
}
