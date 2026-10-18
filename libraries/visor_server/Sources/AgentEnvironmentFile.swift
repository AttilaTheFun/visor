import Foundation
import VisorProtocol

/// What a kind of agent's sessions are given besides Visor's own: the lines
/// of `agents/<kind>.env` in the server's data folder (`KEY=VALUE`; `#`
/// starts a comment), so that, for one, its git commits and pushes are its
/// own GitHub identity's. A PATH there goes before the agent's own search
/// path rather than in its place.
enum AgentEnvironmentFile {
    static func read(_ kind: AgentKind, in folder: URL = ServerPlatform.current.host.dataDirectory,
                     base: [String: String] = ToolPath.environment()) -> [String: String] {
        let file = folder.appendingPathComponent("agents", isDirectory: true).appendingPathComponent(kind.rawValue + ".env")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: equals)...])
        }
        if let first = values.removeValue(forKey: "PATH") {
            let joined = ServerPlatform.current.tools.searchPath(first, before: base)
            for (key, value) in joined where key.caseInsensitiveCompare("PATH") == .orderedSame { values[key] = value }
        }
        return values
    }
}
