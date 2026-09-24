// What one line of a Claude Code session file says. The file is the
// conversation as Claude Code itself keeps it — a record per user message,
// per assistant content block, per tool result, plus bookkeeping records
// that carry no conversation and are skipped. Sidechains (subagents'
// conversations) are skipped too: they are not what the user said or was
// told.

import Foundation

/// A picture inside a message: the bytes as Claude Code stores them.
public struct ClaudeImage: Sendable, Equatable {
    public let base64: String
    public let mediaType: String?
    public init(base64: String, mediaType: String?) {
        self.base64 = base64
        self.mediaType = mediaType
    }
}

/// One block of an assistant message.
public enum ClaudeBlock: Sendable, Equatable {
    case text(String)
    case thinking
    /// A tool call: its id, the tool's name, and its input as JSON text.
    case toolUse(id: String, name: String, inputJSON: String)
}

/// The tokens a request carried; what the context holds right now.
public struct ClaudeUsage: Sendable, Equatable {
    public let input: Int
    public let cacheCreation: Int
    public let cacheRead: Int
    public let output: Int
    public var contextUsed: Int { input + cacheCreation + cacheRead }
    public init(input: Int, cacheCreation: Int, cacheRead: Int, output: Int) {
        self.input = input
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
        self.output = output
    }
}

/// One record of the conversation.
public struct ClaudeRecord: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// What the user said, with any pictures attached.
        case user(text: String, images: [ClaudeImage])
        /// One assistant message, or one block of it: a message arrives as
        /// several records sharing its id, a block each.
        case assistant(messageID: String, blocks: [ClaudeBlock], stopReason: String?, model: String?, usage: ClaudeUsage?)
        /// What a tool returned.
        case toolResult(toolUseID: String?, text: String, images: [ClaudeImage], isError: Bool)
        /// A title the user gave the session, or Claude Code did.
        case title(String)
    }

    public let uuid: String
    public let kind: Kind
    public let timestamp: String?

    public init(uuid: String, kind: Kind, timestamp: String?) {
        self.uuid = uuid
        self.kind = kind
        self.timestamp = timestamp
    }
}

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
