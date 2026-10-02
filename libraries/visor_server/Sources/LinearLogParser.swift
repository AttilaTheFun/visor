import ClaudeTranscript
import Foundation
import VisorProtocol

/// A log that is a list: each line follows the one before it. The
/// assistant's items between two other kinds of line are one message.
class LinearLogParser {
    private var last: String?
    private var run: String?
    private var counter = 0

    func resume(after key: String?) { last = key }

    /// A line with this key (or a made-up one), following the last.
    func line(key: String?, type: String, record: (String) -> ClaudeRecord.Kind?, timestamp: String?) -> ClaudeLine {
        counter += 1
        let key = key ?? "line-\(counter)-\(UUID().uuidString.prefix(6))"
        let kind = record(key)
        // The user speaking, or a tool answering, ends the assistant's run.
        switch kind {
        case .user?, .toolResult?: run = nil
        default: break
        }
        let line = ClaudeLine(uuid: key, parentUuid: last, type: type,
                              record: kind.map { ClaudeRecord(uuid: key, kind: $0, timestamp: timestamp) })
        last = key
        return line
    }

    /// The message an assistant item belongs to: the run it continues, or
    /// one it starts under its own key.
    func message(_ key: String) -> String {
        if let run { return run }
        run = key
        return key
    }

    static func objects(in data: Data) -> [[String: Any]] {
        data.split(separator: 0x0A).compactMap { line in
            guard !line.isEmpty else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
        }
    }
}
