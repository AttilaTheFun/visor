// The cache in memory: for a host without SQLite, and for tests. Nothing
// outlives the process; the next launch starts over from the server.

import VisorProtocol

public final class MemoryStorage: MessageStorage, @unchecked Sendable {
    private struct Row { var seq: Int; var message: TranscriptEntry; var sourceKey: String? }
    private var sources: [String: SourceState] = [:]
    private var syncs: [String: SyncState] = [:]
    private var nodes: [String: [SourceNode]] = [:]
    private var rows: [String: [String: Row]] = [:]

    public init() {}

    public func transaction(_ body: () throws -> Void) throws { try body() }
    public func sourceState(_ session: String) -> SourceState? { sources[session] }
    public func setSourceState(_ state: SourceState, _ session: String) throws { sources[session] = state }
    public func syncState(_ session: String) -> SyncState? { syncs[session] }
    public func setSyncState(_ state: SyncState, _ session: String) throws { syncs[session] = state }

    public func deleteSession(_ session: String) throws {
        sources[session] = nil; syncs[session] = nil; nodes[session] = nil; rows[session] = nil
    }

    public func insertNodes(_ session: String, _ new: [SourceNode]) throws {
        nodes[session, default: []].append(contentsOf: new)
    }

    public func nodes(_ session: String) -> [SourceNode] { (nodes[session] ?? []).sorted { $0.seq < $1.seq } }

    public func upsertMessage(_ session: String, _ message: TranscriptEntry, seq: Int, sourceKey: String?) throws {
        let kept = rows[session]?[message.id]?.seq
        rows[session, default: [:]][message.id] = Row(seq: kept ?? seq, message: message, sourceKey: sourceKey)
    }

    public func insertMessage(_ session: String, _ message: TranscriptEntry, seq: Int) throws {
        rows[session, default: [:]][message.id] = Row(seq: seq, message: message, sourceKey: nil)
    }

    public func deleteMessages(_ session: String, sourceKeys: Set<String>) throws {
        rows[session] = rows[session]?.filter { $0.value.sourceKey.map { !sourceKeys.contains($0) } ?? true }
    }

    public func deleteMessages(_ session: String) throws { rows[session] = nil }

    private func ordered(_ session: String) -> [Row] { (rows[session]?.values.map { $0 } ?? []).sorted { $0.seq < $1.seq } }

    public func messages(_ session: String, limit: Int, before: Int?) -> (messages: [TranscriptEntry], more: Bool) {
        var all = ordered(session)
        if let before { all = all.filter { $0.seq < before } }
        let page = all.suffix(limit)
        return (page.map(\.message), all.count > limit)
    }

    public func seq(_ session: String, of messageID: String) -> Int? { rows[session]?[messageID]?.seq }

    public func seqRange(_ session: String) -> ClosedRange<Int>? {
        let seqs = rows[session]?.values.map(\.seq) ?? []
        guard let low = seqs.min(), let high = seqs.max() else { return nil }
        return low...high
    }

    public func count(_ session: String) -> Int { rows[session]?.count ?? 0 }

    public func search(_ terms: [String], limit: Int) -> [MessageHit] {
        let wanted = terms.map { $0.lowercased() }
        var hits: [MessageHit] = []
        for (session, table) in rows {
            for row in table.values.sorted(by: { $0.seq < $1.seq }) {
                let lower = row.message.text.lowercased()
                guard wanted.allSatisfy({ lower.contains($0) }) else { continue }
                hits.append(MessageHit(session: session, messageID: row.message.id, role: row.message.role, snippet: Self.snippet(row.message.text, around: wanted[0])))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    /// A few words around the first term.
    static func snippet(_ text: String, around term: String) -> String {
        let lower = text.lowercased()
        guard let range = lower.range(of: term) else { return String(text.prefix(80)) }
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
    }
}
