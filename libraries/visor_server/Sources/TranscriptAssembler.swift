// Claude Code's records into the transcript's rows. A user record is a
// user row; an assistant message arrives a block at a time and becomes a
// row of words and tool calls, with a new row when words follow calls, so
// what was said and what ran keep their order; a tool result is a row of
// its own that carries any picture the tool produced.

import ClaudeTranscript
import Foundation
import VisorProtocol

struct TranscriptAssembler {
    /// The assistant message being assembled, as ordered segments.
    private var assembling: (id: String, segments: [(text: String, activities: [String])])?
    /// The goal set and not yet met: Claude Code records a goal twice as
    /// it is set (its state, and a notice in the user's place), and it is
    /// one card.
    private var openGoal: String?
    /// A goal's card waiting for the command that set it: Claude Code
    /// writes the goal's state just before the user's `/goal`, and the
    /// card reads after it.
    private var pendingGoal: TranscriptEntry?

    /// The rows a record adds or changes. An assistant record returns every
    /// row of its message (the same ids as before, updated in place).
    mutating func rows(for record: ClaudeRecord) -> [TranscriptEntry] {
        // A card held back goes in after the command that set it, or
        // before anything else that comes first.
        if let card = pendingGoal {
            if case .goal(let condition, false, _) = record.kind, condition == openGoal { pendingGoal = nil; return [card] }
            if case .user(let text, _) = record.kind, text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/goal") {
                pendingGoal = nil
                return rowsWithoutPending(for: record) + [card]
            }
            pendingGoal = nil
            return [card] + rowsWithoutPending(for: record)
        }
        return rowsWithoutPending(for: record)
    }

    private mutating func rowsWithoutPending(for record: ClaudeRecord) -> [TranscriptEntry] {
        switch record.kind {
        case .user(let text, let images):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Nothing the user typed: a system prompt Claude Code fed in.
            if trimmed.isEmpty || trimmed.hasPrefix("<") { return [] }
            // What the user attached reaches the agent as a list of paths
            // under the words (Server.deliver); the row shows them as the
            // pictures they are again.
            if trimmed == "/goal clear" || trimmed.hasPrefix("/goal clear ") { openGoal = nil }
            let (words, attached) = Self.attachments(in: trimmed)
            let paths = images.compactMap { AgentImages.save(base64: $0.base64, mediaType: $0.mediaType) } + attached
            return [TranscriptEntry(id: "user-file-" + record.uuid, role: .user, text: words,
                                    images: paths, imageSizes: AgentImages.pixelSizes(paths: paths))]
        case .assistant(let messageID, let blocks, _, _, _):
            if assembling?.id != messageID { assembling = (messageID, [(text: "", activities: [])]) }
            // A loop the agent sets itself: a mark the server keeps the
            // session's loop by (no row a transcript draws).
            var marks: [TranscriptEntry] = []
            for case .toolUse(_, let name, let inputJSON) in blocks {
                if let mark = Self.loopMark(tool: name, inputJSON: inputJSON, at: record.timestamp) {
                    marks.append(TranscriptEntry(id: "loop-file-" + record.uuid, role: .tool, text: mark, toolName: "loop"))
                }
            }
            for block in blocks {
                switch block {
                case .text(let text):
                    guard !text.isEmpty, var segments = assembling?.segments else { continue }
                    if let last = segments.indices.last, segments[last].activities.isEmpty, segments[last].text.isEmpty {
                        segments[last].text = text
                    } else if let last = segments.indices.last, segments[last].activities.isEmpty {
                        segments[last].text += "\n\n" + text
                    } else {
                        segments.append((text: text, activities: []))
                    }
                    assembling?.segments = segments
                case .toolUse(_, let name, let inputJSON):
                    let label = "\(name): \(JSON.summary(JSON.object(inputJSON)))"
                    if let last = assembling?.segments.indices.last { assembling?.segments[last].activities.append(label) }
                case .thinking:
                    continue
                }
            }
            guard let assembling else { return marks }
            return assembling.segments.enumerated().compactMap { index, segment in
                guard !segment.text.isEmpty || !segment.activities.isEmpty else { return nil }
                return TranscriptEntry(id: index == 0 ? assembling.id : "\(assembling.id)#\(index)", role: .assistant,
                                       text: segment.text, activities: segment.activities)
            } + marks
        case .toolResult(_, let text, let images, _):
            let paths = images.compactMap { AgentImages.save(base64: $0.base64, mediaType: $0.mediaType) }
            return [TranscriptEntry(id: "tool-file-" + record.uuid, role: .tool, text: String(text.prefix(400)),
                                    toolName: "tool_result", images: paths, imageSizes: AgentImages.pixelSizes(paths: paths))]
        case .title:
            return []
        case .goal(let condition, let met, let reason):
            // The same goal again, as it is set: the one card.
            if !met, openGoal == condition { return [] }
            openGoal = met ? nil : condition
            // A row the transcript shows as the goal's card: set, with
            // what it asks; met, with why it is.
            let card = TranscriptEntry(id: "goal-file-" + record.uuid, role: .tool, text: met ? (reason ?? condition) : condition,
                                       toolName: met ? "goal-met" : "goal")
            // Set: held until the command that set it has gone in.
            if !met { pendingGoal = card; return [] }
            return [card]
        }
    }

    /// The loop a tool call sets: "wake <seconds since 1970>" for a
    /// wake-up (`ScheduleWakeup`), "cron <schedule>" for a repeating job
    /// (`CronCreate`), "stop" for either ended; nil for any other call.
    static func loopMark(tool: String, inputJSON: String, at timestamp: String?) -> String? {
        let input = JSON.object(inputJSON) ?? [:]
        switch tool {
        case "ScheduleWakeup":
            if input["stop"] as? Bool == true { return "stop" }
            guard let delay = (input["delaySeconds"] as? NSNumber)?.doubleValue else { return nil }
            let start = timestamp.flatMap(Self.date(from:)) ?? Date()
            return "wake \(Int(start.timeIntervalSince1970 + delay))"
        case "CronCreate":
            guard let cron = input["cron"] as? String, !cron.isEmpty else { return nil }
            return input["recurring"] as? Bool == false ? nil : "cron " + cron
        case "CronDelete":
            return "stop"
        default:
            return nil
        }
    }

    private static func date(from text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// A user's words and the files attached to them, from the text the
    /// agent was given: the words, then "Attached image:" (or images,
    /// file, files) and a "- path" line for each.
    static func attachments(in text: String) -> (text: String, paths: [String]) {
        for heading in ["Attached images:", "Attached image:", "Attached files:", "Attached file:"] {
            let marker: String
            if text.hasPrefix(heading + "\n") {
                marker = heading + "\n"
            } else if text.contains("\n\n" + heading + "\n") {
                marker = "\n\n" + heading + "\n"
            } else {
                continue
            }
            guard let range = text.range(of: marker, options: .backwards) else { continue }
            let lines = text[range.upperBound...].split(separator: "\n", omittingEmptySubsequences: true)
            // Only a list of paths, to the end: anything else is words.
            guard !lines.isEmpty, lines.allSatisfy({ $0.hasPrefix("- /") }) else { continue }
            return (String(text[..<range.lowerBound]), lines.map { String($0.dropFirst(2)) })
        }
        return (text, [])
    }

    /// A whole file as rows.
    static func rows(in records: [ClaudeRecord]) -> [TranscriptEntry] {
        var assembler = TranscriptAssembler()
        var out: [TranscriptEntry] = []
        for record in records {
            for row in assembler.rows(for: record) {
                if let index = out.firstIndex(where: { $0.id == row.id }) { out[index] = row } else { out.append(row) }
            }
        }
        return out
    }
}
