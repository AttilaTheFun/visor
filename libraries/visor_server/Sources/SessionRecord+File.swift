// The agent's own log as the transcript of record: found, read into the
// cache, followed as it grows, and reconciled with what the user sent.

import ClaudeTranscript
import Foundation
import MessageCache
import VisorProtocol

extension SessionRecord {
    /// Waits until the file has been read in once more than `count`.
    func waitForFile(past count: Int, timeout: TimeInterval = 5) async {
        let limit = Date().addingTimeInterval(timeout)
        while fileLoads <= count, Date() < limit { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// Told to the user when the chat leaves a branch behind.
    static func forkNotice(lost: Int) -> String {
        let gone = lost == 1 ? "One message shown here" : "\(lost) messages shown here"
        return "Another Claude Code resumed this session and sent a newer message on a different branch: the session was forked. The chat now follows that newer branch. \(gone) before this was on the branch left behind and is no longer part of the conversation."
    }

    /// Reads the session's file into the transcript and follows it from
    /// there. Rows the server made itself for what the user said stay
    /// where they are; the file's copy of the same words is not a second
    /// row. Called once the agent has a session id, and again after a
    /// restart (the file is found and read again).
    func followFile() {
        guard let id = process.resumeID else { return }
        stopFollowing()
        let agent = info.agent, cwd = info.cwd, session = info.id
        following = Task { [weak self] in
            // Not written yet (the agent announces its id before its first
            // record): looked for again shortly, for as long as a first
            // turn could take.
            var log = AgentLog.locate(agent: agent, id: id, cwd: cwd)
            var looks = 0
            while log == nil, looks < 240 {
                looks += 1
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                log = AgentLog.locate(agent: agent, id: id, cwd: cwd)
            }
            guard let log, !Task.isCancelled else { return }
            // The cache catches up with the file off the main actor and
            // hands over the window to show; then each line as the agent
            // writes it.
            let indexer = SessionIndexer(store: ServerCache.shared, sessionID: session, url: log.url, window: Self.servedRows, format: log.format)
            self?.indexer = indexer
            for await event in indexer.events() {
                guard let self else { return }
                switch event {
                case .loaded(let loaded): self.apply(loaded: loaded)
                case .lines(let lines): self.apply(lines: lines)
                }
            }
        }
    }

    /// The file is no longer read: the session has ended, or is about to
    /// be read again.
    func stopFollowing() {
        following?.cancel()
        following = nil
        indexer = nil
    }

    /// The file as read: the conversation is the branch that holds its
    /// last line — what an agent resuming now would continue. If the last
    /// prompt this chat showed is on a branch beside it, the session was
    /// forked elsewhere and moved on; the chat follows, and says so.
    func apply(loaded: SessionIndexer.Loaded) {
        var forked = false
        if let last = shownPrompts.last, loaded.abandoned.contains(last) {
            notice = Self.forkNotice(lost: shownPrompts.filter { loaded.abandoned.contains($0) }.count)
            forked = true
        }
        let told = notice != nil
        shownPrompts = Array(loaded.prompts.suffix(Self.rememberedPrompts))
        moreBefore = loaded.more
        let before = entries.map(\.id)
        if !loaded.rows.isEmpty {
            entries = loaded.rows
            settle(in: entries)
        }
        // A goal or loop set before the rows shown: the cache has it.
        noteMarks(lookingBack: true)
        // Forked elsewhere: the thread is another branch. Clients start
        // again from it (a new generation, answered whole, with `reset`)
        // and are told why (the notice).
        if forked { startNewGeneration() }
        if told || entries.map(\.id) != before { onFileReplaced?() }
        // A session read from its file for the first time has no summary yet.
        if info.preview == nil { noteLatest(at: info.created) }
        fileLoads += 1
    }

    /// Lines of the conversation as the agent writes them.
    func apply(lines: [SessionIndexer.Line]) {
        var changed: [TranscriptEntry] = []
        for line in lines {
            if line.isPrompt, !isOurs(prompt: line.record) {
                // A prompt this server did not send: another agent is on
                // the session. With no agent of ours running, the file as
                // it stands now is what the next one resumes — read it
                // again, which tells the user if that means a fork. With
                // ours mid-turn the row is shown like any other, and the
                // branch is worked out when the agent restarts.
                if process.processID == nil { followFile(); return }
            }
            if line.isPrompt, let uuid = line.uuid {
                shownPrompts.append(uuid)
                if shownPrompts.count > Self.rememberedPrompts * 2 { shownPrompts.removeFirst(Self.rememberedPrompts) }
            }
            for row in line.rows where take(fileRow: row) { changed.append(row) }
        }
        if !changed.isEmpty { onFileRows?(changed) }
    }

    /// How many of these rows are the user's, in these words.
    func userRows(_ rows: [TranscriptEntry], saying text: String) -> Int {
        rows.filter { $0.role == .user && Self.sameWords($0.text, text) }.count
    }

    /// Drops the words sent that these rows now carry.
    func settle(in rows: [TranscriptEntry]) {
        unwritten.removeAll { userRows(rows, saying: $0.text) > $0.seen }
    }

    /// Whether a prompt in the file is one this server sent — words it has
    /// sent and not yet seen written — or one the agent fed itself (a
    /// command's expansion, a reminder).
    func isOurs(prompt record: ClaudeRecord?) -> Bool {
        guard case .user(let text, _)? = record?.kind else { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("<") { return true }
        return unwritten.contains { Self.sameWords(trimmed, $0.text) }
    }

    /// Follows the file the first time anyone looks at a resumed session.
    func followFileIfNeeded() {
        guard indexer == nil else { return }
        followFile()
    }

    /// Whether the file's copy of a user message is the server's: the
    /// same words, or the same words followed by the attached pictures'
    /// paths the server added for the agent.
    static func sameWords(_ fileText: String, _ rowText: String) -> Bool {
        // Both trimmed: the file keeps the prompt without the whitespace
        // around it, and a message typed on a phone often ends in a space.
        let file = fileText.trimmingCharacters(in: .whitespacesAndNewlines)
        let row = rowText.trimmingCharacters(in: .whitespacesAndNewlines)
        return file == row || (!row.isEmpty && file.hasPrefix(row + "\n\nAttached "))
            || (row.isEmpty && file.hasPrefix("Attached "))
    }

    /// Puts one row from the file into the transcript: a new row goes on the
    /// end, a row it already has (a reply growing) changes in place.
    func take(fileRow row: TranscriptEntry) -> Bool {
        if row.role == .assistant { dropStream(carriedBy: row.id) }
        if let index = entries.firstIndex(where: { $0.id == row.id }) { entries[index] = row } else { entries.append(row) }
        if row.role == .user { settle(in: entries) }
        noteLatest()
        return true
    }
}
