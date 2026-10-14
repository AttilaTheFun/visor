// An agent's events applied to the record: what is streaming, and the
// turn's status.

import ClaudeTranscript
import Foundation
import MessageCache
import VisorProtocol

extension SessionRecord {
    /// A row from the record carries the stream with the same message id
    /// (the row's id is the message id, or the message id with a segment
    /// suffix): the stream has served and goes.
    func dropStream(carriedBy rowID: String) {
        let base = rowID.split(separator: "#").first.map(String.init) ?? rowID
        streams.removeAll { $0.id == base }
    }

    /// Whether the record carries a message: a row with its id, or that
    /// id with a segment suffix.
    func carries(messageID id: String) -> Bool {
        entries.contains { $0.role == .assistant && ($0.id == id || $0.id.hasPrefix(id + "#")) }
    }

    /// Applies an agent event to the transcript and returns the envelope
    /// that tells a subscriber the same thing — or nothing, for an event
    /// the record has overtaken.
    func apply(_ event: AgentEvent) -> Envelope? {
        switch event {
        case .delta(let id, let text):
            // A message already on the record is finished: its row can
            // reach the record before the last of its streamed words are
            // applied here, and words taken after it would only stand as
            // a stream nothing ever settles.
            guard !carries(messageID: id) else { return nil }
            if let last = streams.indices.last, streams[last].id == id { streams[last].text += text }
            else { streams.append((id: id, text: text)) }
            return .delta(session: info.id, message: id, text: text)
        case .activity(let label):
            activity = label
            return .activity(session: info.id, label)
        case .thinking(let on):
            turn.thinking(on)
            return .status(session: info.id, items: turn.items)
        case .toolStarted(let id, let name, let label, let tasks):
            turn.started(id: id, name: name, label: label, tasks: tasks)
            return .status(session: info.id, items: turn.items)
        case .toolFinished(let id):
            turn.finished(id: id)
            return .status(session: info.id, items: turn.items)
        case .busy(let value):
            info.busy = value
            // A wake-up that has come and gone with no next one set: the
            // loop is over.
            if !value, let wake = info.loopWake, wake < Date().timeIntervalSince1970 {
                info.loopWake = nil
                onInfoChanged?()
            }
            if !value {
                info.pendingApproval = nil
                turn.clear()
                // A stream is not cleared by the turn ending: it stays
                // until the record carries its row. Only an agent whose
                // rows never come from a file lets the turn's end clear it.
                if indexer == nil { streams = [] }
                // What the record carries by now has served.
                streams.removeAll { carries(messageID: $0.id) }
            }
            return .busy(session: info.id, value)
        case .failure(let message):
            error = message
            return .failure(session: info.id, message)
        case .context(let used, let limit):
            info.contextUsed = used
            if let limit { info.contextLimit = limit }
            // The sessions list carries it; the caller broadcasts that.
            return nil
        case .session(let id):
            refreshResume()
            // Said at each turn's start: the file is followed again only
            // for a conversation it is not following already.
            if indexer == nil || followed != id { followFile() }
            return nil
        case .commands(let list):
            commands = list
            return nil
        case .background(let items):
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
        case .memory(let bytes):
            info.memory = bytes
            return nil
        case .spent(let total):
            let added = reportedUsage.map { total.continues(from: $0) ? total.since($0) : total } ?? total
            reportedUsage = total
            info.usage = (info.usage ?? SessionUsage()).adding(added)
            // The sessions list carries it; the caller broadcasts that.
            return nil
        case .plan, .limits:
            // The account's, not the session's: the server keeps them.
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
