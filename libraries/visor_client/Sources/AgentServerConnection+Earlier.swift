import MessageCache
import VisorProtocol

// The rows before the first shown, a page at a time: from this device's
// cache while it has them, from the server past that. Reading, decoding
// and writing them happen off the main actor; the main actor only puts a
// page in front of the rows, and the thread's bottom anchor keeps what is
// on screen where it is.
extension AgentServerConnection {
    /// How many earlier rows go in at once.
    static let earlierPage = 200

    /// Asks for the rows before the first one the transcript has. Asked
    /// again while a page is on its way, it does nothing.
    public func loadEarlier(_ sessionID: String) {
        let transcript = transcript(for: sessionID)
        guard !transcript.loadingEarlier, let before = transcript.entries.first?.id else { return }
        transcript.loadingEarlier = true
        let cache = Self.cache, key = cacheKey(sessionID), limit = Self.earlierPage
        Task { [weak self] in
            let page = await Self.cacheQueue.read { () -> (messages: [TranscriptEntry], more: Bool)? in
                guard let seq = cache.seq(of: before, in: key) else { return nil }
                return cache.messages(in: key, limit: limit, before: seq)
            }
            // The thread was replaced while the cache was read.
            guard let self, transcript.entries.first?.id == before else {
                transcript.loadingEarlier = false
                return
            }
            if let page, !page.messages.isEmpty {
                // Whether the server has rows before the cache's first is
                // not known here: until it has said it has none, assume so.
                transcript.putEarlier(page.messages, more: page.more || !transcript.reachedStart)
            } else {
                // Past what this device has: the server's.
                transcript.earlierAsked = before
                self.server.loadEarlier(sessionID, before: before)
            }
        }
    }

    /// The server's rows before the one asked about: all of them kept on
    /// this device, the last page of them shown, the rest read from the
    /// cache when the thread reaches them.
    func takeEarlier(_ envelope: Envelope, for sessionID: String) {
        guard let transcript = transcripts[sessionID], let before = transcript.earlierAsked else { return }
        transcript.earlierAsked = nil
        // The thread was replaced while the page was on its way.
        guard transcript.entries.first?.id == before else {
            transcript.loadingEarlier = false
            return
        }
        let rows = envelope.entries ?? []
        let more = envelope.more ?? false
        if !rows.isEmpty {
            let cache = Self.cache, key = cacheKey(sessionID)
            Self.cacheQueue.write {
                // Only in front of the row asked about, and only when it is
                // the first kept: anywhere else would leave a gap.
                guard let seq = cache.seq(of: before, in: key),
                      cache.messages(in: key, limit: 1, before: seq).messages.isEmpty else { return }
                try? cache.prepend(key, rows)
            }
        }
        let page = Array(rows.suffix(Self.earlierPage))
        let added = transcript.putEarlier(page, more: more || rows.count > page.count)
        note("thread \(sessionID.prefix(8)): \(added) earlier rows put in above")
        // Nothing new (a server before 0.19 answers a row past its own
        // with rows the thread has): asking again would bring the same, so
        // the thread goes no further back rather than spin for ever.
        if !more { transcript.reachedStart = true }
        if !rows.isEmpty, added == 0 {
            transcript.reachedStart = true
            transcript.hasEarlier = false
        }
    }

    /// After the channel comes back: asks again for any page that was on
    /// its way when it dropped.
    func askEarlierAgain() {
        for (id, transcript) in transcripts {
            if let before = transcript.earlierAsked { server.loadEarlier(id, before: before) }
        }
    }
}
