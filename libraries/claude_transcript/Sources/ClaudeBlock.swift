import Foundation

/// One block of an assistant message.
public enum ClaudeBlock: Sendable, Equatable {
    case text(String)
    case thinking
    /// A tool call: its id, the tool's name, and its input as JSON text.
    case toolUse(id: String, name: String, inputJSON: String)
}
