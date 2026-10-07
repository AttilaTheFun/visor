// An agent's events applied to the record: what is streaming, the
// turn's status, the terminal's screen.

import ClaudeTranscript
import Foundation
import MessageCache
import VisorProtocol

extension SessionRecord {
    /// Where the last screen begins in these bytes: the start of the
    /// full-screen interface (\u{1B}[?1049h) or a full clear (\u{1B}[2J).
    static func lastRange(of text: String, in data: Data) -> Range<Data.Index>? {
        let marker = Data(text.utf8)
        var found: Range<Data.Index>?
        var search = data.startIndex
        while let range = data[search...].range(of: marker) {
            found = range
            search = range.upperBound
            if search >= data.endIndex { break }
        }
        return found
    }

    static func screenBoundary(in data: Data) -> Data.Index? {
        var found: Data.Index?
        for marker in [Data("\u{1B}[?1049h".utf8), Data("\u{1B}[2J".utf8)] {
            var search = data.startIndex
            while let range = data[search...].range(of: marker) {
                found = max(found ?? range.lowerBound, range.lowerBound)
                search = range.upperBound
                if search >= data.endIndex { break }
            }
        }
        return found
    }

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
        case .session:
            refreshResume()
            followFile()
            return nil
        case .commands(let list):
            commands = list
            return nil
        case .background(let items):
            guard info.background != items else { return nil }
            info.background = items
            // The sessions list carries it; the caller broadcasts that.
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
        case .tty(let data):
            // A window that attaches later is given these bytes to build
            // the screen from, so they must begin where a screen begins.
            // A full clear, or the start of the full-screen interface,
            // supersedes everything drawn before it — which both bounds
            // what is kept and keeps a replay from starting mid-sequence.
            if let last = Self.lastRange(of: "\u{1B}[?1049h", in: data) {
                altScreen = Self.lastRange(of: "\u{1B}[?1049l", in: data).map { $0.lowerBound < last.lowerBound } ?? true
            } else if Self.lastRange(of: "\u{1B}[?1049l", in: data) != nil {
                altScreen = false
            }
            if let boundary = Self.screenBoundary(in: data) {
                var kept = Data(data.suffix(from: boundary))
                // A screen that began with a clear is still the full-screen
                // one: the window is told so, or it would build it on the
                // ordinary screen and restore a page that never existed.
                let enter = Data("\u{1B}[?1049h".utf8)
                if altScreen, !kept.starts(with: enter) { kept = enter + kept }
                scrollback = kept
            } else {
                scrollback.append(data)
                if scrollback.count > Self.scrollbackLimit {
                    scrollback.removeFirst(scrollback.count - Self.scrollbackLimit)
                }
            }
            // Not broadcast: the terminal belongs to one window.
            onTerminalBytes?(.tty(session: info.id, data: data.base64EncodedString()))
            return nil
        }
    }
}
