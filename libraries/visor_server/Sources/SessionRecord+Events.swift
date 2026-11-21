// An agent's events applied to the record: the turn's state, and its
// status.

import ClaudeTranscript
import Foundation
import MessageCache
import VisorAgent
import VisorProtocol

extension SessionRecord {
    /// Where the turn stands now, from what the record holds
    /// (TurnState+Precedence): what the server tells when it changes
    /// (VisorServer+Turn).
    var currentTurn: TurnState {
        TurnState.of(approval: info.pendingApproval, signIn: signIn?.url != nil, busy: info.busy, sending: sending,
                     responding: responding, status: turn.items, background: backgroundKnown ? info.background : [])
    }

    /// Applies an agent event to the transcript and returns the envelope
    /// that tells a subscriber the same thing — or nothing, for an event
    /// the record has overtaken. Streamed words return nothing: they say
    /// only that the agent is responding, which the turn's state tells.
    func apply(_ event: AgentEvent) -> Envelope? {
        switch event {
        case .delta:
            // Words coming: the agent is responding. Its words are not
            // kept or told (the message's row brings them), so a piece of
            // them costs nothing past the first.
            sending = false
            responding = true
            return nil
        case .turnBegan:
            sending = false
            return nil
        case .activity(let label):
            activity = label
            return .activity(session: info.id, label)
        case .thinking(let on):
            // A block of the message began (thinking, a tool's call, more
            // words): the words before it have stopped.
            sending = false
            responding = false
            turn.thinking(on)
            return .status(session: info.id, items: turn.items)
        case .toolStarted(let id, let name, let label, let tasks):
            sending = false
            responding = false
            turn.started(id: id, name: name, label: label, tasks: tasks)
            return .status(session: info.id, items: turn.items)
        case .toolFinished(let id):
            // Its result came, whether it worked or failed: the agent
            // takes it up next.
            responding = false
            turn.finished(id: id)
            return .status(session: info.id, items: turn.items)
        case .busy(let value):
            // A turn beginning or ending: nothing of the last one's words.
            if value != info.busy { responding = false }
            info.busy = value
            noteDelivered()
            // A wake-up that has come and gone with no next one set: the
            // loop is over.
            if !value, let wake = info.loopWake, wake < Date().timeIntervalSince1970 {
                info.loopWake = nil
                onInfoChanged?()
            }
            if !value {
                info.pendingApproval = nil
                turn.clear()
                turnPickedUp = false
                sending = false
            }
            return .busy(session: info.id, value)
        case .failure(let message):
            sending = false
            error = message
            return .failure(session: info.id, message)
        case .context(let used, let limit):
            info.contextUsed = used
            if let limit { info.contextLimit = limit }
            // The sessions list carries it; the caller broadcasts that.
            return nil
        case .session(let id):
            forkMade(as: id)
            refreshResume()
            // Said at each turn's start: the file is followed again only
            // for a conversation it is not following already.
            if indexer == nil || followed != id { followFile() }
            return nil
        case .commands(let list):
            commands = list
            return nil
        case .rows(let rows):
            // Taken as the file's rows are, and told to clients the same way.
            var changed: [TranscriptEntry] = []
            for row in rows where take(fileRow: row) { changed.append(row) }
            if !changed.isEmpty { onFileRows?(changed) }
            return nil
        case .background(let items):
            backgroundKnown = true
            guard info.background != items else { return nil }
            info.background = items
            // The sessions list carries it; the caller broadcasts that.
            return nil
        case .goal(let goal, let met):
            goalReported = true
            goalMet = met
            info.goal = goal
            // The sessions list carries it; the caller broadcasts that.
            return nil
        case .notice(let words):
            notice = words
            return ephemeralEnvelope
        case .manual(let words):
            setPermissions(skip: false)
            notice = words
            return ephemeralEnvelope
        case .memory(let bytes):
            info.memory = bytes
            // Nil once the agent has gone, and its background with it.
            if bytes == nil { backgroundEnded() }
            return nil
        case .question(let request):
            sending = false
            info.pendingApproval = request
            return .approval(session: info.id, request)
        case .withdrawn(let id):
            guard info.pendingApproval?.id == id else { return nil }
            info.pendingApproval = nil
            return .approval(session: info.id, nil)
        case .spent(let total):
            let added = reportedUsage.map { total.continues(from: $0) ? total.since($0) : total } ?? total
            reportedUsage = total
            info.usage = (info.usage ?? SessionUsage()).adding(added)
            // The sessions list carries it; the caller broadcasts that.
            return nil
        case .plan, .limits:
            // The account's, not the session's: the server keeps them.
            return nil
        case .subagents:
            // Read from the agent's files by the server (VisorServer+Subagents).
            return nil
        case .model(let model):
            // What actually ran, for display only. The user's choice
            // (info.model) is never changed here — a turn that fell back
            // to another model must not make that model stick.
            info.reportedModel = model
            return nil
        }
    }
}
