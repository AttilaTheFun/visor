import ClaudeTranscript
import Foundation

/// Where a branch made at a row of a Claude conversation goes on from: the
/// last record of that row's turn, its reply whole and its tool calls with
/// their results, so the copy ends where a turn ends and never on a tool
/// call waiting for its result. Claude Code's `--resume-session-at` takes
/// it.
enum ClaudeForkPoint {
    /// In the conversation's file, by the agent's own session id.
    static func point(row: String, id: String, cwd: String) -> String? {
        guard let url = ClaudeSessionFiles.locate(sessionID: id, cwd: cwd) else { return nil }
        return point(row: row, in: ClaudeTranscriptParser.lines(contentsOf: url).compactMap(\.record))
    }

    static func point(row: String, in records: [ClaudeRecord]) -> String? {
        guard let start = records.firstIndex(where: { Self.record($0, isRow: row) }) else { return nil }
        // On to the turn's end: the record before the next prompt.
        var last = start
        for index in records.indices.dropFirst(start + 1) {
            if case .user = records[index].kind { break }
            last = index
        }
        return records[last].uuid
    }

    /// Whether a transcript row was made from this record: an assistant
    /// row is its message's (a later part of it "<id>#<n>"); the others
    /// are named after their record ("user-file-<uuid>", "tool-file-…").
    static func record(_ record: ClaudeRecord, isRow row: String) -> Bool {
        if case .assistant(let messageID, _, _, _, _) = record.kind, row.split(separator: "#").first.map(String.init) == messageID {
            return true
        }
        return row == record.uuid || row.hasSuffix("-file-" + record.uuid)
    }
}
