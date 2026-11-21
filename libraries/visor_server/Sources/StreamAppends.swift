// The words of the replies being written, gathered between a session's
// flushes (VisorServer+Streams): Claude Code gives 30 to 60 pieces a
// second, and subscribers are told of them five times a second instead,
// each message's words as one append that says where it goes.

/// The words streamed since subscribers were last told: one append per
/// message, in the order the messages began.
struct StreamAppends {
    /// One message's words since the last flush: where they go (the length,
    /// in UTF-8 bytes, of its words before them) and what they are.
    struct Append: Equatable {
        let id: String
        let from: Int
        var text: String
    }

    private(set) var appends: [Append] = []

    var isEmpty: Bool { appends.isEmpty }

    /// More words of message `id`, whose words before them are `from`
    /// bytes long. Ones that don't follow what waits for it (the stream
    /// was cleared and began again) start its append over.
    mutating func add(id: String, from: Int, text: String) {
        if let index = appends.firstIndex(where: { $0.id == id }) {
            if appends[index].from + appends[index].text.utf8.count == from {
                appends[index].text += text
                return
            }
            appends.remove(at: index)
        }
        appends.append(Append(id: id, from: from, text: text))
    }

    /// What waits, taken: nothing waits after.
    mutating func take() -> [Append] {
        defer { appends = [] }
        return appends
    }

    /// Nothing waits: the streams it was of are gone.
    mutating func clear() { appends = [] }
}
