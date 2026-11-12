import VisorProtocol

/// A session's inbox and outbox (docs/agent-mail.md): what it was sent and
/// what it sent, kept with the session for as long as it is kept, and
/// deleted with it. Each box keeps its newest `kept` messages: a box past
/// that lets its oldest go, read ones first in the inbox.
struct Mailbox: Codable, Equatable {
    static let kept = 100

    var inbox: [MailMessage] = []
    var outbox: [MailMessage] = []

    var unread: Int { inbox.count(where: \.unread) }
    var isEmpty: Bool { inbox.isEmpty && outbox.isEmpty }

    /// The turn an agent is told it has mail by, its whole input this one
    /// line: how many messages are unread, never their words, so they
    /// don't fill its context.
    static func notice(unread: Int) -> String {
        "[Visor: you have \(unread) unread message\(unread == 1 ? "" : "s") in your inbox; read them with read_inbox]"
    }

    /// Whether a turn's words are a mail notice, known by its form.
    static func isNotice(_ text: String) -> Bool {
        text.hasPrefix("[Visor: you have ") && text.hasSuffix(" in your inbox; read them with read_inbox]")
    }

    /// A message delivered to this session, once: one already here (the
    /// same id, carried twice) stays as it is.
    mutating func receive(_ message: MailMessage) {
        guard !inbox.contains(where: { $0.id == message.id }) else { return }
        inbox.append(message)
        if inbox.count > Self.kept, let oldest = inbox.firstIndex(where: { !$0.unread }) ?? inbox.indices.first {
            inbox.remove(at: oldest)
        }
    }

    /// A message this session sent.
    mutating func send(_ message: MailMessage) {
        outbox.removeAll { $0.id == message.id }
        outbox.append(message)
        if outbox.count > Self.kept { outbox.removeFirst(outbox.count - Self.kept) }
    }

    /// What became of a message this session sent: whether it was one of
    /// its own. A message's state only goes forward (a read one is never
    /// delivered again).
    @discardableResult
    mutating func update(sent id: String, to state: MailMessage.State, problem: String? = nil, at now: Double) -> Bool {
        guard let index = outbox.firstIndex(where: { $0.id == id }) else { return false }
        guard Self.order(state) > Self.order(outbox[index].state) else { return true }
        outbox[index].state = state
        outbox[index].changed = now
        outbox[index].problem = problem
        return true
    }

    /// The inbox's messages to read, oldest first: the last `count` of the
    /// unread ones, or of all of them. Those unread are marked read here;
    /// the ids of those newly read are given back, for their senders.
    mutating func read(unreadOnly: Bool, count: Int, at now: Double) -> (messages: [MailMessage], newlyRead: [String]) {
        let chosen = inbox.indices.filter { !unreadOnly || inbox[$0].unread }.suffix(max(1, count))
        var messages: [MailMessage] = []
        var newlyRead: [String] = []
        for index in chosen {
            messages.append(inbox[index])
            if inbox[index].unread {
                inbox[index].state = .read
                inbox[index].changed = now
                newlyRead.append(inbox[index].id)
            }
        }
        return (messages, newlyRead)
    }

    /// Waiting, then delivered, then read; failing or expiring ends a
    /// message that was waiting.
    private static func order(_ state: MailMessage.State) -> Int {
        switch state {
        case .waiting: 0
        case .delivered: 1
        case .failed, .expired: 2
        case .read: 3
        }
    }
}
