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

    /// The rows a record adds or changes. An assistant record returns every
    /// row of its message (the same ids as before, updated in place).
    mutating func rows(for record: ClaudeRecord) -> [TranscriptEntry] {
        switch record.kind {
        case .user(let text, let images):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Nothing the user typed: a system prompt Claude Code fed in.
            if trimmed.isEmpty || trimmed.hasPrefix("<") { return [] }
            // What the user attached reaches the agent as a list of paths
            // under the words (Server.deliver); the row shows them as the
            // pictures they are again.
            let (words, attached) = Self.attachments(in: trimmed)
            let paths = images.compactMap { AgentImages.save(base64: $0.base64, mediaType: $0.mediaType) } + attached
            return [TranscriptEntry(id: "user-file-" + record.uuid, role: .user, text: words,
                                    images: paths, imageSizes: AgentImages.pixelSizes(paths: paths))]
        case .assistant(let messageID, let blocks, _, _, _):
            if assembling?.id != messageID { assembling = (messageID, [(text: "", activities: [])]) }
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
            guard let assembling else { return [] }
            return assembling.segments.enumerated().compactMap { index, segment in
                guard !segment.text.isEmpty || !segment.activities.isEmpty else { return nil }
                return TranscriptEntry(id: index == 0 ? assembling.id : "\(assembling.id)#\(index)", role: .assistant,
                                       text: segment.text, activities: segment.activities)
            }
        case .toolResult(_, let text, let images, _):
            let paths = images.compactMap { AgentImages.save(base64: $0.base64, mediaType: $0.mediaType) }
            return [TranscriptEntry(id: "tool-file-" + record.uuid, role: .tool, text: String(text.prefix(400)),
                                    toolName: "tool_result", images: paths, imageSizes: AgentImages.pixelSizes(paths: paths))]
        case .title:
            return []
        case .goal(let condition, let met, let reason):
            // A row the transcript shows as the goal's card: set, with
            // what it asks; met, with why it is.
            return [TranscriptEntry(id: "goal-file-" + record.uuid, role: .tool, text: met ? (reason ?? condition) : condition,
                                    toolName: met ? "goal-met" : "goal")]
        }
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
