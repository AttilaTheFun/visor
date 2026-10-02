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

    /// Holds a message, and its files, until the turn ends.
    func enqueue(_ text: String, images: [String] = []) {
        info.queued.append(text)
        queuedImages.append(images)
    }

    /// Takes the outbox, leaving it empty: everything said, in order, as
    /// one message, with every file it carried.
    func takeQueue() -> (text: String, images: [String]) {
        let text = info.queued.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let images = queuedImages.flatMap { $0 }
        info.queued = []
        queuedImages = []
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
