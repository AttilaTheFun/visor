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

    /// Sets the rows as a change would, for tests.
    func replaceEntriesForTesting(_ rows: [TranscriptEntry]) { entries = rows }

    /// The rows changed since a revision, each with the row it follows
    /// ("" for the first), and the rows removed since — or every row, for
    /// a revision from before the generation began.
    func rows(since: Int) -> (rows: [TranscriptEntry], after: [String], removed: [String]) {
        let start = max(0, entries.count - Self.servedRows)
        var rows: [TranscriptEntry] = []
        var after: [String] = []
        // A row never stamped came with the record, before any revision.
        for index in start..<entries.count where (rowSeq[entries[index].id] ?? 0) > since {
            rows.append(entries[index])
            after.append(index > 0 ? entries[index - 1].id : "")
        }
        let removed = removedAt.filter { $0.value > since }.map(\.key)
        return (rows, after, removed)
    }

    /// The record, or the rows of it changed since a revision the client
    /// holds — with the generation, so the client knows whether it may
    /// merge these as a delta or must take them as the whole.
    func transcriptEnvelope(since: Int?) -> Envelope {
        let delta = since.map { rows(since: $0) }
        var e = Envelope.transcript(session: info.id, entries: delta?.rows ?? Array(entries.suffix(Self.servedRows)), streaming: streaming,
                                    activity: activity, busy: info.busy, error: error)
        if let delta {
            e.after = delta.after
            e.removed = delta.removed
        } else {
            // The rows as a whole: the client replaces what it holds.
            e.reset = true
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
            let start = max(0, index - Self.servedRows)
            e.entries = Array(entries[start..<index])
            e.more = start > 0 || moreBefore
            return e
        }
        guard let indexer, let first = entries.first?.id else {
            e.entries = []
            e.more = false
            return e
        }
        let page = await indexer.earlier(before: first, limit: Self.servedRows)
        e.entries = page.rows
        e.more = page.more
        return e
    }
}
