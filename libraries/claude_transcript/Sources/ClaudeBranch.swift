// Which of a session file's branches is the conversation.
//
// Resumed twice, a session is written by two agents, each continuing
// from where it stood: the file grows two branches from that point.
// Claude Code, resuming, takes the branch that holds the last message of
// the file — nothing else, not a timestamp, decides it (measured) — and
// the other branch is no longer part of the conversation. A reader that
// knows where the conversation stood (its head: the prompt that began
// its latest turn, which everything in the turn descends from) keeps to
// that branch instead, past whatever another agent wrote beside it, and
// says the file went on elsewhere; the server then resumes its agent at
// the branch's newest message (`--resume-session-at`). Lines that are
// not messages (attachments, snapshots, which Claude Code writes between
// them and may hang off an older message) never decide the branch.
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

    /// A line as the tree needs it: its place, whether it begins a turn,
    /// and whether it is a message (the user's or the assistant's) rather
    /// than something written beside one.
    public struct Node: Sendable {
        public let uuid: String?
        public let parentUuid: String?
        public let isPrompt: Bool
        public let isMessage: Bool
        public init(uuid: String?, parentUuid: String?, isPrompt: Bool, isMessage: Bool = true) {
            self.uuid = uuid; self.parentUuid = parentUuid; self.isPrompt = isPrompt; self.isMessage = isMessage
        }
    }

    /// The branch, from the tree alone — for lines kept somewhere that
    /// holds their places but not their words (the transcript cache).
    public struct Shape: Sendable {
        public let members: Set<String>
        public let abandoned: Set<String>
        public let prompts: [String]
        public let abandonedPrompts: Int
        /// The prompt that began the conversation's latest turn: where it
        /// stands, for the next reading to keep to.
        public let head: String?
        /// The conversation's newest message: where an agent resumes it.
        public let leaf: String?
        /// The file's newest message is on another branch: something else
        /// carried the session on from beside this conversation.
        public let wentOnElsewhere: Bool
    }

    public static func current(of lines: [ClaudeLine]) -> ClaudeBranch {
        let shape = current(nodes: lines.map { Node(uuid: $0.uuid, parentUuid: $0.parentUuid, isPrompt: $0.isPrompt, isMessage: $0.isMessage) })
        var records: [ClaudeRecord] = []
        for line in lines {
            if let uuid = line.uuid, shape.abandoned.contains(uuid) { continue }
            if let record = line.record { records.append(record) }
        }
        return ClaudeBranch(records: records, members: shape.members, abandoned: shape.abandoned,
                            prompts: shape.prompts, abandonedPrompts: shape.abandonedPrompts)
    }

    /// The branch from the tree alone. With `head` (the prompt the
    /// conversation's latest turn began with, when it was last read), the
    /// one that carries on from it; without, the one that holds the file's
    /// newest message.
    public static func current(nodes lines: [Node], head: String? = nil) -> Shape {
        var parent: [String: String] = [:]
        var children: [String: [String]] = [:]
        // The line before each, in file order: what a line with no parent
        // of its own continues from. Claude Code starts a fresh chain at
        // a compaction (a boundary line with no parent), and the
        // conversation before it is still the conversation.
        var previous: [String: String] = [:]
        var known = Set<String>()
        var last: String?
        var newestMessage: String?
        for line in lines {
            guard let uuid = line.uuid else { continue }
            known.insert(uuid)
            if let last { previous[uuid] = last }
            last = uuid
            if let p = line.parentUuid {
                parent[uuid] = p
                children[p, default: []].append(uuid)
            }
            if line.isMessage { newestMessage = uuid }
        }
        /// What a line carries on from: its parent, or across a boundary
        /// (or a parent the file does not hold) the line before.
        func above(_ u: String) -> String? {
            if let p = parent[u], known.contains(p) { return p }
            return previous[u]
        }
        // Where the conversation ends: the newest message that carries on
        // from the head; without a head, the newest message.
        var leaf = newestMessage ?? last
        if let head, known.contains(head) {
            var carriesOn: Set<String> = [head]
            leaf = head
            for line in lines {
                guard let uuid = line.uuid, uuid != head, let from = above(uuid), carriesOn.contains(from) else { continue }
                carriesOn.insert(uuid)
                if line.isMessage { leaf = uuid }
            }
        }
        // The chain: the end and everything above it.
        var chain = Set<String>()
        var cursor = leaf
        while let u = cursor, !chain.contains(u) {
            chain.insert(u)
            cursor = above(u)
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
        let wentOnElsewhere = newestMessage.map { !members.contains($0) } ?? false
        return Shape(members: members, abandoned: abandoned, prompts: prompts, abandonedPrompts: abandonedPrompts,
                     head: prompts.last, leaf: leaf, wentOnElsewhere: wentOnElsewhere)
    }
}
