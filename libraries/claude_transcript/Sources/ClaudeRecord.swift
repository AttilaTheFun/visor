// What one line of a Claude Code session file says. The file is the
// conversation as Claude Code itself keeps it — a record per user message,
// per assistant content block, per tool result, plus bookkeeping records
// that carry no conversation and are skipped. Sidechains (subagents'
// conversations) are skipped too: they are not what the user said or was
// told.

import Foundation

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
        /// A goal the user set (`/goal`): Claude keeps working until it is
        /// met. Set, or met with the reason Claude Code judged it so.
        case goal(condition: String, met: Bool, reason: String?)
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
