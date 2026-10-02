import Foundation
import Synchronization
import VisorProtocol

/// JSON helpers over JSONSerialization (the agents' streams are loosely typed).
enum JSON {
    static func object(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A short, one-line summary of a tool's input for an activity label.
    static func summary(_ input: Any?, limit: Int = 80) -> String {
        guard let dict = input as? [String: Any] else { return "" }
        let preferred = ["command", "file_path", "path", "pattern", "query", "url", "description", "prompt", "notebook_path"]
        var text = ""
        for key in preferred {
            if let value = dict[key] as? String, !value.isEmpty { text = value; break }
        }
        if text.isEmpty, let first = dict.values.compactMap({ $0 as? String }).first { text = first }
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }
}
