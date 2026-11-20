// One line of a Claude Code conversation as the prefilter keeps it, or
// nothing. Kept, each headed with when it was (`[2026-11-20 14:05]`, UTC):
//
//   PERSON: …                          the person's words (a slash command
//                                      as typed, a queued message, answers)
//   AGENT: …                           the agent's text replies
//   CLAUDE'S COMPACTION SUMMARY: …     Claude Code's own summary of all before
//                                      it (the `isCompactSummary` user line),
//                                      and the `compact_boundary` beside it
//   TOOL <name>: <key arguments>       a tool call, as one line
//   → …                                its result's first lines
//   MAIL FROM/TO …: …                  mail between sessions, as one line
//
// Dropped: thinking, images (counted), system reminders (every one; they
// repeat), the agent's bookkeeping lines (attachments, API records,
// queue operations, …), subagents' sidechains, and all but the start of
// a tool's output.

import ClaudeTranscript
import Foundation
import VisorProtocol

extension SuperCompactFilter {
    /// A tool result's lines kept, and its characters at most.
    static let resultLines = 4
    static let resultCharacters = 400
    /// A message's characters at most (the person's or the agent's): a
    /// pasted log is not the conversation.
    static let messageCharacters = 20_000
    /// A tool call's arguments, and a mail's words, at most.
    static let lineCharacters = 240

    /// The record kinds that can hold conversation: a line that begins as
    /// another kind (an API record, the queue's, …) is passed over unread.
    static let conversationTypes: Set<String> = ["user", "assistant", "attachment", "system", "summary", "custom-title"]

    /// One line of the file as the text kept of it; nil for one that is
    /// dropped.
    static func entry(_ line: Data) -> String? {
        if let type = leadingType(line), !conversationTypes.contains(type) { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String, object["isSidechain"] as? Bool != true else { return nil }
        let kept: [String] = switch type {
        case "user": user(object)
        case "assistant": assistant(object)
        case "attachment": attachment(object)
        case "system": system(object)
        case "summary": (object["summary"] as? String).map { ["SUMMARY: " + oneLine($0, lineCharacters)] } ?? []
        case "custom-title": (object["customTitle"] as? String).map { ["TITLE: " + oneLine($0, lineCharacters)] } ?? []
        default: []
        }
        guard !kept.isEmpty else { return nil }
        let stamp = self.stamp(object["timestamp"] as? String)
        return kept.map { stamp.isEmpty ? $0 : "[\(stamp)] " + $0 }.joined(separator: "\n")
    }

    /// The type a line begins with, when it begins with it
    /// (`{"type":"api-request-blob",…`): read without parsing the line.
    static func leadingType(_ line: Data) -> String? {
        let prefix = Array(#"{"type":""#.utf8)
        guard line.count > prefix.count, line.prefix(prefix.count).elementsEqual(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count).prefix(64)
        guard let end = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: rest[rest.startIndex..<end], as: UTF8.self)
    }

    /// `2026-11-20T14:05:09.123Z` as `2026-11-20 14:05`.
    static func stamp(_ timestamp: String?) -> String {
        guard let timestamp, timestamp.count >= 16 else { return "" }
        return String(timestamp.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }

    // MARK: The kinds of line

    private static func user(_ object: [String: Any]) -> [String] {
        // What Claude Code wrote in the person's place (a picture's
        // description, a command's note) is not theirs.
        guard object["isMeta"] as? Bool != true, let message = object["message"] as? [String: Any] else { return [] }
        if object["isCompactSummary"] as? Bool == true {
            let text = withoutReminders(text(of: message["content"]).text)
            return text.isEmpty ? [] : ["CLAUDE'S COMPACTION SUMMARY:\n" + text]
        }
        if let answers = ClaudeTranscriptParser.answers(object["toolUseResult"]) {
            return ["PERSON ANSWERED: " + answers.map { "\($0.question) → \($0.answer)" }.joined(separator: "; ")]
        }
        if let parts = message["content"] as? [[String: Any]] {
            let results = parts.filter { $0["type"] as? String == "tool_result" }
            if !results.isEmpty { return results.compactMap(toolResult) }
        }
        let (text, images) = text(of: message["content"])
        return words(text, images: images).map { [$0] } ?? []
    }

    private static func assistant(_ object: [String: Any]) -> [String] {
        guard let message = object["message"] as? [String: Any], let parts = message["content"] as? [[String: Any]] else { return [] }
        return parts.compactMap { part -> String? in
            switch part["type"] as? String {
            case "text":
                let text = withoutReminders(part["text"] as? String ?? "")
                guard !text.isEmpty else { return nil }
                if let mail = AgentMessageMarkers.outbound(text) {
                    return "MAIL TO \(mail.session) on \(mail.computer): " + oneLine(mail.body, lineCharacters)
                }
                return "AGENT: " + capped(text, messageCharacters)
            case "tool_use":
                return toolCall(name: part["name"] as? String ?? "tool", input: part["input"] as? [String: Any] ?? [:])
            default:
                // Thinking, redacted or not, and whatever else: dropped.
                return nil
            }
        }
    }

    private static func attachment(_ object: [String: Any]) -> [String] {
        guard let attachment = object["attachment"] as? [String: Any] else { return [] }
        switch attachment["type"] as? String {
        case "queued_command":
            // A message sent while the agent worked, taken into its turn.
            guard (attachment["commandMode"] as? String ?? "prompt") == "prompt" else { return [] }
            let (text, images) = text(of: attachment["prompt"])
            return words(text, images: images).map { [$0] } ?? []
        case "goal_status":
            guard let condition = attachment["condition"] as? String else { return [] }
            let met = attachment["met"] as? Bool == true
            return [(met ? "GOAL MET: " : "GOAL SET: ") + oneLine(condition, lineCharacters)]
        default:
            return []
        }
    }

    private static func system(_ object: [String: Any]) -> [String] {
        guard object["subtype"] as? String == "compact_boundary" else { return [] }
        let metadata = object["compactMetadata"] as? [String: Any] ?? [:]
        let trigger = metadata["trigger"] as? String ?? "?"
        let before = (metadata["preTokens"] as? Int).map { ", \($0) tokens before" } ?? ""
        return ["--- Claude Code compacted the conversation here (\(trigger)\(before)) ---"]
    }

    // MARK: Words, calls and results

    /// The person's words, or mail, or a notice, as kept.
    static func words(_ raw: String, images: Int) -> String? {
        let text = withoutReminders(raw)
        let dropped = images > 0 ? " " + imagesDropped(images) : ""
        guard !text.isEmpty else { return images > 0 ? "PERSON:" + dropped : nil }
        if let mail = mail(text) { return mail }
        if text.hasPrefix("<task-notification>") {
            let summary = tag("summary", in: text) ?? tag("status", in: text) ?? "finished"
            return "TASK NOTIFICATION: " + oneLine(summary, lineCharacters)
        }
        if text.hasPrefix("<local-command-") {
            return "COMMAND OUTPUT: " + oneLine(tag("local-command-stdout", in: text) ?? text, lineCharacters)
        }
        if let condition = ClaudeTranscriptParser.goalNotice(text) { return "GOAL SET: " + oneLine(condition, lineCharacters) }
        let said = ClaudeTranscriptParser.command(text) ?? text
        return "PERSON: " + capped(said, messageCharacters) + dropped
    }

    /// Mail, in any of the forms the server hands it over in, as one line:
    /// a message headed with its sender, one beginning `@@from`, or the
    /// notice that messages wait in the inbox.
    static func mail(_ text: String) -> String? {
        guard TurnOrigin.isMail(text) else { return nil }
        if let inbound = AgentMessageMarkers.inbound(text) {
            return "MAIL FROM \(inbound.session) on \(inbound.computer): " + oneLine(inbound.body, lineCharacters)
        }
        guard text.hasPrefix("[Message from the Visor session") else { return "MAIL: " + oneLine(text, lineCharacters) }
        // `[Message from the Visor session “<name>” (<id>) on <computer> (server …), to … ]` and the words below.
        let header = text.prefix { $0 != "\n" }
        let name = between("“", "”", in: String(header)) ?? "?"
        let id = between("” (", ")", in: String(header)) ?? "?"
        let body = text.dropFirst(header.count)
        return "MAIL FROM “\(name)” (\(id)): " + oneLine(String(body), lineCharacters)
    }

    /// A tool call as one line: its name and its key arguments. A message
    /// sent with Visor's send_message is mail.
    static func toolCall(name: String, input: [String: Any]) -> String {
        if name.hasSuffix("send_message"), let session = input["session"] as? String {
            return "MAIL TO \(session) (send_message): " + oneLine(input["text"] as? String ?? "", lineCharacters)
        }
        let keys = ["command", "file_path", "notebook_path", "path", "pattern", "glob", "url", "query", "repo", "pr", "number", "issue",
                    "branch", "base", "head", "tag", "session", "server", "skill", "subagent_type", "description", "title", "subject", "prompt"]
        var shown: [String] = []
        for key in keys where shown.count < 3 {
            guard let value = scalar(input[key]), !value.isEmpty else { continue }
            shown.append(shown.isEmpty && ["command", "file_path", "notebook_path", "path"].contains(key) ? value : "\(key)=\(value)")
        }
        if shown.isEmpty {
            for key in input.keys.sorted() where shown.count < 2 {
                if let value = scalar(input[key]), !value.isEmpty { shown.append("\(key)=\(value)") }
            }
        }
        let arguments = oneLine(shown.joined(separator: " "), lineCharacters)
        return arguments.isEmpty ? "TOOL \(name)" : "TOOL \(name): \(arguments)"
    }

    /// A tool's result as its first lines.
    static func toolResult(_ part: [String: Any]) -> String? {
        let (raw, images) = text(of: part["content"])
        let error = part["is_error"] as? Bool == true
        let text = withoutReminders(raw)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var pieces: [String] = []
        if !lines.isEmpty {
            var kept = capped(lines.prefix(resultLines).joined(separator: " ⏎ "), resultCharacters)
            if lines.count > resultLines { kept += " … (+\(lines.count - resultLines) lines)" }
            pieces.append(kept)
        }
        if images > 0 { pieces.append(imagesDropped(images)) }
        guard !pieces.isEmpty || error else { return nil }
        return (error ? "→ ERROR:" : "→") + (pieces.isEmpty ? "" : " " + pieces.joined(separator: " "))
    }

    static func imagesDropped(_ count: Int) -> String { "[\(count) image\(count == 1 ? "" : "s") dropped]" }

    // MARK: Text

    /// A content value's text and how many pictures it holds: a string, or
    /// blocks.
    static func text(of value: Any?) -> (text: String, images: Int) {
        if let text = value as? String { return (text, 0) }
        guard let parts = value as? [[String: Any]] else { return ("", 0) }
        let text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        return (text, parts.filter { $0["type"] as? String == "image" }.count)
    }

    /// Without its system reminders (every `<system-reminder>…</system-reminder>`),
    /// trimmed.
    static func withoutReminders(_ text: String) -> String {
        guard text.contains("<system-reminder>") else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "<system-reminder>") {
            out += rest[..<open.lowerBound]
            guard let close = rest.range(of: "</system-reminder>", range: open.upperBound..<rest.endIndex) else {
                rest = ""
                break
            }
            rest = rest[close.upperBound...]
        }
        out += rest
        // Where one was cut out, no more than one blank line is left.
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// On one line, its spaces collapsed, cut at `limit` characters.
    static func oneLine(_ text: String, _ limit: Int) -> String {
        capped(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "), limit)
    }

    /// Cut at `limit` characters, saying how many more there were.
    static func capped(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + " … [\(text.count - limit) more characters cut]"
    }

    private static func scalar(_ value: Any?) -> String? {
        switch value {
        case let text as String: oneLine(text, lineCharacters)
        case let number as Int: String(number)
        case let number as Double: String(number)
        case let flag as Bool: String(flag)
        default: nil
        }
    }

    private static func tag(_ name: String, in text: String) -> String? {
        between("<\(name)>", "</\(name)>", in: text)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func between(_ open: String, _ close: String, in text: String) -> String? {
        guard let start = text.range(of: open), let end = text.range(of: close, range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }
}
