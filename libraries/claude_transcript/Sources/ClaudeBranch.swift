// Which of a session file's branches is the conversation.
//
// Resumed twice, a session is written by two agents, each continuing
// from where it stood: the file grows two branches from that point.
// Claude Code, resuming, takes the branch that holds the last line of
// the file — nothing else, not a timestamp, decides it (measured) — and
// the other branch is no longer part of the conversation.
//
// A healthy file branches too: an assistant message calling several
// tools at once is written as sibling lines, and their results attach
// beside one another. So the branches that matter are only the ones a
// prompt begins — a prompt is how an agent starts a turn, and a fork is
// two agents starting a turn from the same place. A prompt off the
// chain of the last line, and everything under it, is the abandoned
// branch; everything else is the conversation.

import Foundation

public struct ClaudeBranch: Sendable {
    /// The conversation: every record not on an abandoned branch, in
    /// file order.
    public let records: [ClaudeRecord]
    /// Every line the conversation holds, by uuid — the set a new line's
    /// parent must be in to be part of it.
    public let members: Set<String>
    /// The lines of every abandoned branch, by uuid.
    public let abandoned: Set<String>
    /// The conversation's prompts, in order. The last is the mark a later
    /// look at the file compares to, to tell whether the conversation
    /// moved on from here or was forked away from it.
    public let prompts: [String]
    public var lastPrompt: String? { prompts.last }
    /// How many prompts the abandoned branches hold.
    public let abandonedPrompts: Int

    /// A line as the tree needs it: its place, and whether it begins a turn.
    public struct Node: Sendable {
        public let uuid: String?
        public let parentUuid: String?
        public let isPrompt: Bool
        public init(uuid: String?, parentUuid: String?, isPrompt: Bool) {
            self.uuid = uuid; self.parentUuid = parentUuid; self.isPrompt = isPrompt
        }
    }

    /// The branch, from the tree alone — for lines kept somewhere that
    /// holds their places but not their words (the transcript cache).
    public struct Shape: Sendable {
        public let members: Set<String>
        public let abandoned: Set<String>
        public let prompts: [String]
        public let abandonedPrompts: Int
    }

    public static func current(of lines: [ClaudeLine]) -> ClaudeBranch {
        let shape = current(nodes: lines.map { Node(uuid: $0.uuid, parentUuid: $0.parentUuid, isPrompt: $0.isPrompt) })
        var records: [ClaudeRecord] = []
        for line in lines {
            if let uuid = line.uuid, shape.abandoned.contains(uuid) { continue }
            if let record = line.record { records.append(record) }
        }
        return ClaudeBranch(records: records, members: shape.members, abandoned: shape.abandoned,
                            prompts: shape.prompts, abandonedPrompts: shape.abandonedPrompts)
    }

    public static func current(nodes lines: [Node]) -> Shape {
        var parent: [String: String] = [:]
        var children: [String: [String]] = [:]
        // The line before each, in file order: what a line with no parent
        // of its own continues from. Claude Code starts a fresh chain at
        // a compaction (a boundary line with no parent), and the
        // conversation before it is still the conversation.
        var previous: [String: String] = [:]
        var known = Set<String>()
        var last: String?
        var leaf: String?
        for line in lines {
            guard let uuid = line.uuid else { continue }
            known.insert(uuid)
            if let last { previous[uuid] = last }
            last = uuid
            if let p = line.parentUuid {
                parent[uuid] = p
                children[p, default: []].append(uuid)
                leaf = uuid
            } else if leaf == nil {
                leaf = uuid
            }
        }
        // The chain: the last line and everything above it — through a
        // boundary, or a parent the file does not hold, to the line before.
        var chain = Set<String>()
        var cursor = leaf
        while let u = cursor, !chain.contains(u) {
            chain.insert(u)
            if let p = parent[u], known.contains(p) { cursor = p } else { cursor = previous[u] }
        }
        // A prompt off the chain begins an abandoned branch.
        var abandoned = Set<String>()
        var abandonedPrompts = 0
        for line in lines where line.isPrompt {
            guard let uuid = line.uuid, !chain.contains(uuid), !abandoned.contains(uuid) else { continue }
            var stack = [uuid]
            while let u = stack.popLast() {
                guard abandoned.insert(u).inserted else { continue }
                stack += children[u] ?? []
            }
        }
        var members = Set<String>()
        var prompts: [String] = []
        for line in lines {
            if let uuid = line.uuid, abandoned.contains(uuid) {
                if line.isPrompt { abandonedPrompts += 1 }
                continue
            }
            if let uuid = line.uuid { members.insert(uuid) }
            if line.isPrompt, let uuid = line.uuid { prompts.append(uuid) }
        }
        return Shape(members: members, abandoned: abandoned, prompts: prompts, abandonedPrompts: abandonedPrompts)
    }
}
