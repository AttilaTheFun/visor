// What a session's rows say about it at a glance: its goal, its loop, its
// latest message for the list.

import ClaudeTranscript
import Foundation
import MessageCache
import VisorProtocol

extension SessionRecord {
    /// Keeps the session's summary — the start of its latest message and
    /// when it came — after the transcript changed at its end.
    /// The session's goal and loop, as the latest of their marks says:
    /// among the rows held, or (`lookingBack`, on loading) in the cache
    /// for the rows before them.
    func noteMarks(lookingBack: Bool) {
        let goalPrefixes = ["goal-file-"], loopPrefixes = ["loop-file-"], goalClear = ["/goal clear"]
        var goalMark = entries.reversed().lazy.compactMap(Self.goal(of:)).first
        var loopMark = entries.reversed().lazy.compactMap(Self.loop(of:)).first
        if lookingBack {
            if goalMark == nil {
                goalMark = ServerCache.shared.lastMessage(in: info.id, idPrefixes: goalPrefixes, userTexts: goalClear).flatMap(Self.goal(of:))
            }
            if loopMark == nil {
                loopMark = ServerCache.shared.lastMessage(in: info.id, idPrefixes: loopPrefixes).flatMap(Self.loop(of:))
            }
        }
        var next = info
        if let goalMark { next.goal = goalMark }
        if let loopMark { next.loopWake = loopMark.wake; next.loopCron = loopMark.cron }
        guard next.goal != info.goal || next.loopWake != info.loopWake || next.loopCron != info.loopCron else { return }
        info = next
        onInfoChanged?()
    }

    /// Whether the goal just gone was met, not cleared: the latest goal row
    /// is a met one.
    func goalWasMet(_ goal: String) -> Bool {
        guard let row = entries.reversed().first(where: { Self.goal(of: $0) != nil }) else { return false }
        return row.toolName == "goal-met"
    }

    /// The goal a row says the session has now (nil: none), if it is a goal's.
    static func goal(of row: TranscriptEntry) -> String?? {
        if row.role == .user, row.text == "/goal clear" || row.text.hasPrefix("/goal clear ") { return .some(nil) }
        guard row.role == .tool else { return nil }
        switch row.toolName {
        case "goal": return .some(row.text)
        case "goal-met": return .some(nil)
        default: return nil
        }
    }

    /// The loop a row says the session has now, if it is a loop's mark.
    static func loop(of row: TranscriptEntry) -> (wake: Double?, cron: String?)? {
        guard row.role == .tool, row.toolName == "loop" else { return nil }
        if row.text.hasPrefix("wake "), let time = Double(row.text.dropFirst(5)) { return (time, nil) }
        if row.text.hasPrefix("cron ") { return (nil, String(row.text.dropFirst(5))) }
        return (nil, nil)
    }

    func noteLatest(at time: Double = Date().timeIntervalSince1970) {
        guard let preview = entries.reversed().lazy.compactMap(Self.preview(of:)).first else { return }
        guard preview != info.preview else { return }
        info.preview = preview
        info.updated = time
        onInfoChanged?()
    }

    /// Fills the summary at load, so a session lists its latest message
    /// without being opened first. From the end of the session's own file
    /// where there is one: the rows kept in the store can stop short of
    /// the file — the store is written when a turn ends, and the reply's
    /// row reaches it from the file a moment later — and a summary from
    /// them showed the user's question with the answer already on disk.
    /// The time is the file's, so the list sorts by real activity, not by
    /// when the folder was first used. Nothing is broadcast — this runs
    /// before anyone subscribes. A summary saved by an earlier run is
    /// replaced by the file's, which may have moved on since; it stands
    /// only where there is no file to read.
    func primePreview() {
        // The file where it is expected — a single stat, no directory
        // scan at startup: a session whose folder moved just sorts by when
        // it was created, from what was kept, until it is next opened.
        if info.agent == .claude, let id = process.resumeID {
            let url = ClaudeSessionFiles.expectedURL(sessionID: id, cwd: info.cwd)
            if let modified = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date {
                let tail = TranscriptAssembler.rows(in: ClaudeTranscriptParser.tailRecords(contentsOf: url))
                if let preview = tail.reversed().lazy.compactMap(Self.preview(of:)).first {
                    info.preview = preview
                    info.updated = modified.timeIntervalSince1970
                    return
                }
            }
        }
        // No file: from what was kept, made afresh — the rule for a summary
        // may have changed since it was saved — at the time it had.
        let saved = info.preview
        info.preview = nil
        noteLatest(at: info.updated ?? info.created)
        if info.preview == nil { info.preview = saved }
    }

    /// What a row says, in a line or two: its words, else the pictures it
    /// carries. Only what was said, by either side — a tool call or its
    /// result is not a message, and a row of nothing but those is skipped
    /// for the last row that spoke.
    static func preview(of entry: TranscriptEntry) -> String? {
        guard entry.role == .user || entry.role == .assistant else { return nil }
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The server's own notes to the agent (a restart's nudge) are not
        // the conversation's latest word.
        if entry.role == .user, text.hasPrefix("[Visor]") { return nil }
        // Blank lines go: a paragraph break would be the second of the two
        // lines a list shows, and show nothing.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !lines.isEmpty { return String(lines.joined(separator: "\n").prefix(300)) }
        if !entry.images.isEmpty { return entry.images.count == 1 ? "Image" : "\(entry.images.count) images" }
        return nil
    }
}
