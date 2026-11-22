// Where a turn stands, in the words the chat's line under the thread and
// the sessions list's line under a session say it: "Sending…",
// "Thinking…", "Responding…", "Running Bash: bazel test …", "Waiting for
// 2 subagents", "Waiting for approval". Nothing for an idle one.

import VisorProtocol

extension TurnState {
    /// The turn's line; nil when it is idle.
    public var words: String? {
        switch phase {
        case .idle: nil
        case .sending: "Sending…"
        case .thinking: "Thinking…"
        case .responding: "Responding…"
        case .waiting: Self.words(waitingOn: waits)
        }
    }

    /// What sort of work the line is about (a shell, a monitor, a
    /// subagent, another tool), for its symbol; nil for anything else.
    public var work: StatusItem.Kind? { phase == .waiting ? waits.first?.work : nil }

    /// What a waiting turn waits on, the first of it by name: what the
    /// person has to answer first, then subagents counted, then a tool
    /// call or background work by its line, with how many more.
    static func words(waitingOn waits: [TurnWait]) -> String {
        guard let first = waits.first else { return "Waiting…" }
        switch first.kind {
        case .approval: return "Waiting for approval"
        case .question: return "Waiting for your answer"
        case .signIn: return "Waiting for sign-in"
        case .tool, .subagent, .background: break
        }
        let more = waits.count - 1
        if waits.allSatisfy({ $0.kind == .subagent }) {
            if more > 0 { return "Waiting for \(waits.count) subagents" }
            return first.label.isEmpty ? "Waiting for a subagent" : "Waiting for a subagent: \(first.label)"
        }
        let rest = more > 0 ? " and \(more) more" : ""
        switch first.kind {
        case .tool: return "Running \(first.label)\(rest)"
        case .subagent: return "Waiting for a subagent: \(first.label)\(rest)"
        default: return "Waiting on \(first.label)\(rest)"
        }
    }
}
