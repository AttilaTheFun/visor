// What the user says: put in the thread, or held until the turn ends.

import ClaudeTranscript
import Foundation
import MessageCache
import VisorProtocol

extension SessionRecord {
    /// The user's words, handed to the agent. Every agent writes them to
    /// its log, which is the transcript: they are remembered as sent until
    /// the log has them, and are no row until then.
    func appendUser(_ text: String, images: [String] = []) {
        error = nil
        unwritten.append((text: text, seen: userRows(entries, saying: text)))
        // The session's summary is the latest thing said, already.
        if let preview = Self.preview(of: TranscriptEntry(id: "", role: .user, text: text)), preview != info.preview {
            info.preview = preview
            info.updated = Date().timeIntervalSince1970
            onInfoChanged?()
        }
    }

    /// Holds a message, and its files, until the turn ends: behind what
    /// waits already, or (`first`) ahead of it.
    func enqueue(_ text: String, images: [String] = [], first: Bool = false) {
        info.queued.insert(text, at: first ? 0 : info.queued.count)
        queuedImages.insert(images, at: first ? 0 : queuedImages.count)
    }

    /// Whether these words end the session's goal (`/goal clear`).
    static func clearsGoal(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "/goal clear" || trimmed.hasPrefix("/goal clear ")
    }

    /// Takes the first message from the outbox, with its files: messages go
    /// over one at a time, each as it was written, so a slash command
    /// (`/goal clear`) stays a command rather than being run into the words
    /// around it.
    func takeNextQueued() -> (text: String, images: [String])? {
        guard !info.queued.isEmpty else { return nil }
        let text = info.queued.removeFirst()
        let images = queuedImages.isEmpty ? [] : queuedImages.removeFirst()
        return (text, images)
    }

    /// Drops one queued message and its files, or all of them.
    func unqueue(_ text: String?) {
        guard let text else { info.queued = []; queuedImages = []; return }
        guard let index = info.queued.firstIndex(of: text) else { return }
        info.queued.remove(at: index)
        if index < queuedImages.count { queuedImages.remove(at: index) }
    }
}
