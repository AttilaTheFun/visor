import Foundation

extension ClaudeSubagent {
    /// Its conversation as a session of Claude Code's own, `id`, written
    /// beside `sessionFile` (that of the session that sent it off): its
    /// records, no longer marked a sidechain of that session, which
    /// `claude --resume <id>` goes on with. The file, or nil when its
    /// conversation can't be read or the file written.
    public func session(_ id: String, beside sessionFile: URL) -> URL? {
        guard let text = try? String(contentsOf: transcript, encoding: .utf8) else { return nil }
        var lines: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard var record = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            // What was sent to the model for it, not its conversation.
            if (record["type"] as? String)?.hasPrefix("api-request") == true { continue }
            record["sessionId"] = id
            record["isSidechain"] = false
            record["agentId"] = nil
            guard let written = try? JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes]) else { continue }
            lines.append(String(decoding: written, as: UTF8.self))
        }
        guard !lines.isEmpty else { return nil }
        let file = sessionFile.deletingLastPathComponent().appendingPathComponent("\(id).jsonl")
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return file
    }
}
