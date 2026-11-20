// What the user says: put in the thread, or held until the turn ends.

import ClaudeTranscript
import Foundation
import MessageCache
import VisorProtocol

extension SessionRecord {
    /// The user's words, handed to the agent. Every agent writes them to
    /// its log, which is the transcript: they are remembered as sent until
    /// the log has them, and are no row until then.
    func appendUser(_ text: String, images: [String] = [], origin: TurnOrigin = .user) {
        error = nil
        unwritten.append((text: text, seen: userRows(entries, saying: text), orphaned: nil))
        noteDelivered()
        // The session's summary is the latest thing said, already — but
        // never mail, which is no word to the person (latestPreview).
        let row = TranscriptEntry(id: "", role: .user, text: text)
        if !Self.isMail(row), let preview = Self.preview(of: row), preview != info.preview {
            info.preview = preview
            info.updated = Date().timeIntervalSince1970
            onInfoChanged?()
        }
    }

    /// What the agent has been handed and has not written to its log yet,
    /// while it works, as clients are told it (`delivered`): a message
    /// that left the queue is otherwise in neither the queue nor the
    /// thread until the log has it. Not the agent's own commands (`/goal`),
    /// which its log may never write.
    func noteDelivered() {
        let delivered = info.busy
            ? unwritten.filter { $0.orphaned == nil }.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") }
            : []
        guard delivered != info.delivered else { return }
        info.delivered = delivered
        onInfoChanged?()
    }

    /// The agent has gone (exited, or let go of): what it was handed and
    /// its log has not written, it never took — no later agent has those
    /// words. They are no longer on their way; `dropUntaken` lets go of
    /// them once the log has had time to catch up. Whether there were any.
    @discardableResult
    func agentWent() -> Bool {
        let now = ContinuousClock.now
        var any = false
        for index in unwritten.indices where unwritten[index].orphaned == nil {
            unwritten[index].orphaned = now
            any = true
        }
        noteDelivered()
        return any
    }

    /// The words an agent that went at least `grace` ago was handed and
    /// its log still hasn't written: let go of, for the user to be told
    /// (and to say them again).
    func dropUntaken(after grace: Duration) -> [String] {
        let before = ContinuousClock.now - grace
        let untaken = unwritten.filter { $0.orphaned.map { $0 <= before } ?? false }
        unwritten.removeAll { $0.orphaned.map { $0 <= before } ?? false }
        return untaken.map(\.text)
    }

    /// Holds a message, its files and where it came from, until the turn
    /// ends: behind what waits already, or (`first`) ahead of it.
    func enqueue(_ text: String, images: [String] = [], first: Bool = false, origin: TurnOrigin = .user) {
        lineUpQueue()
        info.queued.insert(text, at: first ? 0 : info.queued.count)
        queuedImages.insert(images, at: first ? 0 : queuedImages.count)
        queuedOrigins.insert(origin, at: first ? 0 : queuedOrigins.count)
    }

    /// The files and origins beside the queue, one for each of its
    /// messages: what a message put there without them (or taken out
    /// alone) would leave out of step.
    func lineUpQueue() {
        if queuedImages.count != info.queued.count {
            queuedImages = info.queued.indices.map { $0 < queuedImages.count ? queuedImages[$0] : [] }
        }
        if queuedOrigins.count != info.queued.count {
            queuedOrigins = info.queued.indices.map { $0 < queuedOrigins.count ? queuedOrigins[$0] : Self.origin(of: info.queued[$0]) }
        }
    }

    /// Where words came from, told by their form alone: mail by the forms
    /// the server hands it over in, the server's own nudges by theirs, and
    /// anything else the person's.
    static func origin(of text: String) -> TurnOrigin {
        if TurnOrigin.isMail(text) { return .mail }
        return text.hasPrefix("[Visor]") ? .system : .user
    }

    /// Drops the queued messages that `drop` picks, with their files and
    /// origins.
    func dropQueued(where drop: (String) -> Bool) {
        lineUpQueue()
        for index in info.queued.indices.reversed() where drop(info.queued[index]) {
            info.queued.remove(at: index)
            queuedImages.remove(at: index)
            queuedOrigins.remove(at: index)
        }
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
    ///
    /// A mail notice counts what is unread when its turn comes, and goes
    /// only if any is: messages that came while it waited are in its count,
    /// and ones read meanwhile are not.
    func takeNextQueued() -> (text: String, images: [String], origin: TurnOrigin)? {
        lineUpQueue()
        while !info.queued.isEmpty {
            let text = info.queued.removeFirst()
            let images = queuedImages.removeFirst()
            let origin = queuedOrigins.removeFirst()
            guard Mailbox.isNotice(text) else { return (text, images, origin) }
            // A runner's agent has no inbox to read: its mail comes as turns.
            if !driven, mailbox.unread > 0 { return (Mailbox.notice(unread: mailbox.unread), images, .mail) }
        }
        return nil
    }

    /// Drops one queued message and its files, or all of them.
    func unqueue(_ text: String?) {
        guard let text else { info.queued = []; queuedImages = []; queuedOrigins = []; return }
        lineUpQueue()
        guard let index = info.queued.firstIndex(of: text) else { return }
        info.queued.remove(at: index)
        queuedImages.remove(at: index)
        queuedOrigins.remove(at: index)
    }
}
