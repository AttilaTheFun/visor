// The replies being written, told to a session's subscribers five times a
// second rather than a piece at a time: Claude Code streams 30 to 60
// pieces a second, more than a client can draw or a phone's radio should
// carry. Each flush sends one `delta` per message with what came since the
// last, and `from`, where it goes: the UTF-8 length of the words told
// before it. A client whose words don't meet `from` asks for the state
// again (`state`), which is sent whole.
//
// Order is kept: anything else told of the session (a tool starting, the
// turn's end) first tells what streamed before it, so a client hears the
// words before what followed them, as the agent said them.

import VisorProtocol

extension VisorServer {
    /// How long a session's streamed words wait before they are told: five
    /// flushes a second at most.
    static let streamFlush: Duration = .milliseconds(200)

    /// Words came: told when the session's flush comes, with whatever else
    /// has streamed by then.
    func flushStreamsSoon(_ record: SessionRecord) {
        guard record.streamFlush == nil, !record.unsent.isEmpty else { return }
        record.streamFlush = Task { @MainActor [weak self, weak record] in
            try? await Task.sleep(for: Self.streamFlush)
            guard !Task.isCancelled, let self, let record else { return }
            record.streamFlush = nil
            self.flushStreams(record)
        }
    }

    /// What has streamed since the last flush, told now: one `delta` per
    /// message, in the order the messages began.
    func flushStreams(_ record: SessionRecord) {
        record.streamFlush?.cancel()
        record.streamFlush = nil
        guard !record.unsent.isEmpty else { return }
        for append in record.unsent.take() {
            broadcast(.delta(session: record.info.id, message: append.id, text: append.text, from: append.from), session: record)
        }
    }

    /// `state`: the session's ephemeral state, whole, to the client that
    /// asked (its words of a reply didn't meet a `delta`'s `from`). What
    /// streamed is told first, so the state is where the next `delta`
    /// starts.
    func performState(_ envelope: Envelope, from client: ClientConnection?) {
        guard let client, let record = session(envelope.session) else { return }
        flushStreams(record)
        client.send(record.ephemeralEnvelope)
    }
}
