// The record's rows as clients sync them: each change stamped with a
// revision, a client told what changed since the one it has.

import ClaudeTranscript
import Foundation
import MessageCache
import VisorProtocol

extension SessionRecord {
    /// After the rows changed: which rows are new, different or in a new
    /// place (after a different row) since `old`, stamped with this
    /// revision; and which went. A client can take any change as a delta.
    func stamp(from old: [TranscriptEntry]) {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var oldBefore: [String: String] = [:]
        for index in old.indices.dropFirst() { oldBefore[old[index].id] = old[index - 1].id }
        var present = Set<String>()
        for (index, row) in entries.enumerated() {
            present.insert(row.id)
            removedAt[row.id] = nil
            let before = index > 0 ? entries[index - 1].id : nil
            if oldByID[row.id] != row || oldBefore[row.id] != before { rowSeq[row.id] = revision }
        }
        for row in old where !present.contains(row.id) {
            rowSeq[row.id] = nil
            removedAt[row.id] = revision
        }
        if removedAt.count > Self.rememberedRemovals { startNewGeneration() }
    }

    /// Clients start again from the rows as they are: a delta can no
    /// longer bring them here (or should not — the thread is a new branch).
    func startNewGeneration() {
        removedAt = [:]
        generation += 1
    }

    /// Lets go of the oldest rows once more than `heldRows` are held, down
    /// to `servedRows`, when the store has them (the session's file is
    /// followed into it): what is held here is the end of the conversation
    /// and what is happening, and `earlier` reads the rest from the store.
    /// No change to the conversation: clients aren't told of rows removed
    /// and the revision stays; one whose revision is older than a row let
    /// go of takes the rows as a whole (`transcriptEnvelope`).
    func letGoOfOldRows() {
        guard indexer != nil, entries.count > Self.heldRows else { return }
        let gone = entries.count - Self.servedRows
        let dropped = Array(entries.prefix(gone))
        for row in dropped {
            if let stamped = rowSeq.removeValue(forKey: row.id) { letGoThrough = max(letGoThrough, stamped) }
        }
        // Words sent and not yet written are known by how many rows said
        // them when they went: those let go of no longer count.
        for index in unwritten.indices {
            unwritten[index].seen = max(0, unwritten[index].seen - userRows(dropped, saying: unwritten[index].text))
        }
        firstFollows = entries[gone - 1].id
        moreBefore = true
        lettingGo = true
        entries.removeFirst(gone)
        lettingGo = false
    }

    /// Sets the rows as a change would, for tests.
    func replaceEntriesForTesting(_ rows: [TranscriptEntry]) { entries = rows }

    /// The rows changed since a revision, each with the row it follows
    /// ("" for the first), and the rows removed since — at most `limit`,
    /// in order, from after the row `after` (nil: from the first); `later`
    /// says whether more changed rows follow. Every row held is looked at,
    /// not only the latest: a client far behind is brought up a page at a
    /// time, with nothing skipped.
    func rows(since: Int, after: String? = nil, limit: Int = Int.max)
        -> (rows: [TranscriptEntry], after: [String], removed: [String], later: Bool) {
        var start = 0
        if let after, let index = entries.firstIndex(where: { $0.id == after }) { start = index + 1 }
        var rows: [TranscriptEntry] = []
        var anchors: [String] = []
        var later = false
        // A row never stamped came with the record, before any revision.
        for index in start..<entries.count where (rowSeq[entries[index].id] ?? 0) > since {
            guard rows.count < limit else {
                later = true
                break
            }
            rows.append(entries[index])
            anchors.append(index > 0 ? entries[index - 1].id : "")
        }
        // What went is said once, with the first page.
        let removed = after == nil ? removedAt.filter { $0.value > since }.map(\.key) : []
        return (rows, anchors, removed, later)
    }

    /// The record, or the rows of it changed since a revision the client
    /// holds — a page of them, from after the row `after` — with the
    /// generation, so the client knows whether it may merge these as a
    /// delta or must take them as the whole.
    func transcriptEnvelope(since: Int?, after: String? = nil) -> Envelope {
        // Behind a row let go of: the rows held can't bring it up.
        let since = since.flatMap { $0 < letGoThrough ? nil : $0 }
        let delta = since.map { rows(since: $0, after: after, limit: Self.pageRows) }
        var e = Envelope.transcript(session: info.id, entries: delta?.rows ?? Array(entries.suffix(Self.servedRows)), streaming: streaming,
                                    activity: activity, busy: info.busy, error: error)
        if let delta {
            e.after = delta.after
            e.removed = delta.removed
            if delta.later { e.later = true }
        } else {
            // The rows as a whole: the client replaces what it holds from
            // the row the first of them follows, which it may keep.
            e.reset = true
            let start = entries.count - min(entries.count, Self.servedRows)
            e.follows = start > 0 ? entries[start - 1].id : (moreBefore ? firstFollows : "")
        }
        e.more = moreBefore || entries.count > Self.servedRows
        e.notice = notice
        e.revision = revision
        e.generation = generation
        return e
    }

    /// The rows before one the client has, oldest of them first; `more`
    /// says whether there are rows before those too.
    func earlier(before id: String) async -> Envelope {
        var e = Envelope(type: "earlier")
        e.session = info.id
        // From what is here first; the cache holds what is before that.
        if let index = entries.firstIndex(where: { $0.id == id }), index > 0 {
            let start = max(0, index - Self.pageRows)
            e.entries = Array(entries[start..<index])
            e.more = start > 0 || moreBefore
            return e
        }
        guard let indexer else {
            e.entries = []
            e.more = false
            return e
        }
        // Before the row asked about, wherever it is: the record's first, or
        // one the client has paged to past the record's own rows. (Before
        // the record's first, always, sent a client that had paged that far
        // the rows it had, and it asked again for ever.)
        let page = await indexer.earlier(before: id, limit: Self.pageRows)
        e.entries = page.rows
        e.more = page.more
        return e
    }
}
