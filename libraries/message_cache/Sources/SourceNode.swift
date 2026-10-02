import Synchronization
import VisorProtocol

/// A line of a source that is a tree of lines (Claude Code's file): its
/// place, what it follows, and whether it begins a turn. Sources without
/// a tree keep none.
public struct SourceNode: Sendable, Equatable {
    public let seq: Int
    public let key: String?
    public let parentKey: String?
    public let kind: String
    public let isPrompt: Bool
    public init(seq: Int, key: String?, parentKey: String?, kind: String, isPrompt: Bool) {
        self.seq = seq; self.key = key; self.parentKey = parentKey; self.kind = kind; self.isPrompt = isPrompt
    }
}
