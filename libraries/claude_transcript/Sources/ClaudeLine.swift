import Foundation

/// One line of the file as a node of its tree. Claude Code writes the
/// conversation as a tree: every line names the line it follows, and a
/// session resumed twice grows two branches from the point they parted.
/// Bookkeeping lines are nodes too, so the tree is kept from every line,
/// not only the ones that are conversation.
public struct ClaudeLine: Sendable, Equatable {
    public let uuid: String?
    public let parentUuid: String?
    /// The line's own kind, as Claude Code names it ("user", "assistant",
    /// "system", …).
    public let type: String
    /// What the line says, when it is conversation.
    public let record: ClaudeRecord?

    public init(uuid: String?, parentUuid: String?, type: String, record: ClaudeRecord?) {
        self.uuid = uuid
        self.parentUuid = parentUuid
        self.type = type
        self.record = record
    }

    /// Whether this is something the user said to the agent: the start
    /// of a turn, and the only kind of line a fork begins with.
    public var isPrompt: Bool {
        if case .user = record?.kind { return true }
        return false
    }
}
