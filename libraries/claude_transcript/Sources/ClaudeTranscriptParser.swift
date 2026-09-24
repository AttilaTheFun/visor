// Session file lines into records. Tolerant: a line that is not JSON, or
// is a kind of record we do not know, is skipped rather than fatal — the
// format is Claude Code's own and it grows.

import Foundation

public enum ClaudeTranscriptParser {
    /// Every conversation record in a file, in order.
    public static func records(contentsOf url: URL) -> [ClaudeRecord] {
        lines(contentsOf: url).compactMap(\.record)
    }

    /// Every conversation record in some bytes of the file (whole lines).
    public static func records(in data: Data) -> [ClaudeRecord] {
        lines(in: data).compactMap(\.record)
    }

    /// Every line of a file with its place in the tree, conversation or
    /// not.
    public static func lines(contentsOf url: URL) -> [ClaudeLine] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return lines(in: data)
    }

    /// The conversation records at the end of a file — the last `bytes`
    /// of it, whole lines only — for a look at how a session stands
    /// without reading all of it. The last line of the file is on the
    /// branch a resume would take, so the last of these is the latest
    /// thing said.
    public static func tailRecords(contentsOf url: URL, bytes: Int = 65_536) -> [ClaudeRecord] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        // A read that began mid-line drops that line.
        if start > 0, let newline = data.firstIndex(of: 0x0A) { data = Data(data[data.index(after: newline)...]) }
        return records(in: data)
    }

    public static func lines(in data: Data) -> [ClaudeLine] {
        var out: [ClaudeLine] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let parsed = self.line(from: Data(line)) { out.append(parsed) }
        }
        return out
    }

    public static func record(from line: String) -> ClaudeRecord? {
        record(from: Data(line.utf8))
    }

    public static func record(from line: Data) -> ClaudeRecord? {
        self.line(from: line)?.record
    }

    /// A line as a node of the tree: nil only for a line that is not a
    /// record at all, or belongs to a sidechain.
    public static func line(from line: Data) -> ClaudeLine? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        if object["isSidechain"] as? Bool == true { return nil }
        let uuid = object["uuid"] as? String
        let parent = object["parentUuid"] as? String
        let record = record(type: type, object: object, uuid: uuid ?? UUID().uuidString)
        return ClaudeLine(uuid: uuid, parentUuid: parent, type: type, record: record)
    }

    private static func record(type: String, object: [String: Any], uuid: String) -> ClaudeRecord? {
        // A user record Claude Code wrote itself — the description of a
        // picture it was shown, a note about a command — is not the user's.
        if object["isMeta"] as? Bool == true { return nil }
        let timestamp = object["timestamp"] as? String
        switch type {
        case "custom-title", "ai-title":
            guard let title = (object["customTitle"] ?? object["aiTitle"] ?? object["title"]) as? String, !title.isEmpty else { return nil }
            return ClaudeRecord(uuid: uuid, kind: .title(title.replacingOccurrences(of: "-", with: " ")), timestamp: timestamp)
        case "user":
            guard let message = object["message"] as? [String: Any] else { return nil }
            if let text = message["content"] as? String {
                return ClaudeRecord(uuid: uuid, kind: .user(text: text, images: []), timestamp: timestamp)
            }
            guard let parts = message["content"] as? [[String: Any]] else { return nil }
            // Tool results ride along as user messages; they are not the
            // user's words.
            if let result = parts.first(where: { $0["type"] as? String == "tool_result" }) {
                let (text, images) = content(of: result["content"])
                return ClaudeRecord(uuid: uuid, kind: .toolResult(toolUseID: result["tool_use_id"] as? String, text: text, images: images,
                                                                   isError: result["is_error"] as? Bool == true), timestamp: timestamp)
            }
            let (text, images) = content(of: parts)
            return ClaudeRecord(uuid: uuid, kind: .user(text: text, images: images), timestamp: timestamp)
        case "assistant":
            guard let message = object["message"] as? [String: Any], let parts = message["content"] as? [[String: Any]] else { return nil }
            let blocks: [ClaudeBlock] = parts.compactMap { part in
                switch part["type"] as? String {
                case "text": return (part["text"] as? String).map(ClaudeBlock.text)
                case "thinking": return .thinking
                case "tool_use":
                    let input = (try? JSONSerialization.data(withJSONObject: part["input"] ?? [:])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    return .toolUse(id: part["id"] as? String ?? "", name: part["name"] as? String ?? "tool", inputJSON: input)
                default: return nil
                }
            }
            var usage: ClaudeUsage?
            if let u = message["usage"] as? [String: Any] {
                usage = ClaudeUsage(input: u["input_tokens"] as? Int ?? 0, cacheCreation: u["cache_creation_input_tokens"] as? Int ?? 0,
                                    cacheRead: u["cache_read_input_tokens"] as? Int ?? 0, output: u["output_tokens"] as? Int ?? 0)
            }
            return ClaudeRecord(uuid: uuid, kind: .assistant(messageID: message["id"] as? String ?? uuid, blocks: blocks,
                                                             stopReason: message["stop_reason"] as? String, model: message["model"] as? String,
                                                             usage: usage), timestamp: timestamp)
        default:
            // system, summary, queue-operation, attachment, last-prompt and
            // whatever comes next: bookkeeping, not conversation.
            return nil
        }
    }

    /// The text and pictures of a content value: a string, or blocks.
    private static func content(of value: Any?) -> (String, [ClaudeImage]) {
        if let text = value as? String { return (text, []) }
        guard let parts = value as? [[String: Any]] else { return ("", []) }
        let text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        let images = parts.compactMap { part -> ClaudeImage? in
            guard part["type"] as? String == "image", let source = part["source"] as? [String: Any],
                  let data = source["data"] as? String else { return nil }
            return ClaudeImage(base64: data, mediaType: source["media_type"] as? String)
        }
        return (text, images)
    }
}
