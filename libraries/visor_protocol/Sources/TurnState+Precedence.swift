// The one state a turn is in when several things are true at once, the
// same on the server (SessionRecord's `turnState`) and on a client that
// hears a server from before turn states (SessionTranscript's
// `turnState`). From the most pressing down:
//
// 1. an approval, a question or a sign-in the person has to answer;
// 2. a tool call or a subagent running, until its result comes;
// 3. the reply being written (words coming);
// 4. thinking: the agent has the message and is thinking, or has said
//    nothing yet;
// 5. sending: the person's message is on its way, and the agent hasn't
//    begun;
// 6. with no turn running, the work the agent left in the background (a
//    monitor, a command run in the background, a subagent), which wakes it
//    when it ends;
// 7. idle.

extension TurnState {
    /// The turn's state, from what is true of it now.
    /// - Parameters:
    ///   - approval: the approval or questions waiting for the person.
    ///   - signIn: Claude's sign-in waits for its code.
    ///   - busy: a turn is running.
    ///   - sending: the person's message has been handed over, and the
    ///     agent hasn't said anything since.
    ///   - responding: the agent's words are what it did last.
    ///   - status: the turn's status lines (TurnStatus): those running
    ///     that aren't thinking or the task list are what it waits on.
    ///   - background: what the agent runs in the background
    ///     (`SessionInfo.background`), waited on only between turns.
    public static func of(approval: ApprovalRequest?, signIn: Bool, busy: Bool, sending: Bool, responding: Bool,
                          status: [StatusItem], background: [StatusItem]) -> TurnState {
        var asked: [TurnWait] = []
        if let approval {
            let question = approval.questions?.isEmpty == false
            asked.append(TurnWait(kind: question ? .question : .approval, id: approval.id, label: approval.summary.isEmpty ? approval.tool : approval.summary))
        }
        if signIn { asked.append(TurnWait(kind: .signIn, id: "sign-in", label: "Claude")) }
        if !asked.isEmpty { return TurnState(.waiting, waits: asked) }
        if busy {
            let calls = status.filter { $0.running && $0.kind != .thinking && $0.kind != .tasks }.map { wait(for: $0, background: false) }
            if !calls.isEmpty { return TurnState(.waiting, waits: calls) }
            if responding { return TurnState(.responding) }
            return TurnState(sending ? .sending : .thinking)
        }
        if sending { return TurnState(.sending) }
        let left = background.filter(\.running).map { wait(for: $0, background: true) }
        if !left.isEmpty { return TurnState(.waiting, waits: left) }
        return .idle
    }

    /// A status line as something waited on: a subagent by its
    /// description (its line says "Waiting: ‹description›", which the
    /// words that show it say their own way), anything else by its line.
    static func wait(for item: StatusItem, background: Bool) -> TurnWait {
        if item.kind == .subagent {
            let label = item.label.hasPrefix(waitingPrefix) ? String(item.label.dropFirst(waitingPrefix.count)) : item.label
            return TurnWait(kind: .subagent, id: item.id, label: label, work: .subagent)
        }
        return TurnWait(kind: background ? .background : .tool, id: item.id, label: item.label, work: item.kind)
    }

    /// How an agent's line for a subagent it waits on begins (ClaudeOutput's
    /// and CodexOutput's labels).
    static let waitingPrefix = "Waiting: "
}
