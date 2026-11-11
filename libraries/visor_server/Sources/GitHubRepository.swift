// The GitHub repository a session's folder is a checkout of, as owner/name:
// what an MCP endpoint's `$SESSION_REPOSITORY` header says (Keymaster scopes
// what a session may ask for by it).

import Foundation
import VisorSystem

enum GitHubRepository {
    /// The folder's `origin` (else its first remote), as owner/name; nil
    /// when the folder is in no checkout, or its remote isn't GitHub's.
    static func of(folder: String) async -> String? {
        var remote = await ProjectSurvey.git(["config", "--get", "remote.origin.url"], in: folder)
        if remote?.isEmpty != false, let first = await ProjectSurvey.git(["remote"], in: folder)?.split(separator: "\n").first {
            remote = await ProjectSurvey.git(["remote", "get-url", String(first)], in: folder)
        }
        return remote.flatMap(name(ofRemote:))
    }

    /// The same, read from the checkout's `.git/config` alone, at once (no
    /// git run): for an agent being started. `origin`'s URL, in the folder
    /// or the nearest above it that has a `.git` folder; nil otherwise.
    static func ofCheckout(folder: String) -> String? {
        var directory = URL(fileURLWithPath: HostFolders.resolve(folder), isDirectory: true)
        for _ in 0..<32 {
            let config = directory.appendingPathComponent(".git/config")
            if let text = try? String(contentsOf: config, encoding: .utf8) {
                var inOrigin = false
                for line in text.split(whereSeparator: \.isNewline) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("[") { inOrigin = trimmed == "[remote \"origin\"]"; continue }
                    if inOrigin, trimmed.hasPrefix("url"), let equals = trimmed.firstIndex(of: "=") {
                        return name(ofRemote: String(trimmed[trimmed.index(after: equals)...]))
                    }
                }
                return nil
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
        return nil
    }

    /// owner/name from a remote's URL: `https://github.com/owner/name(.git)`,
    /// `git@github.com:owner/name(.git)` or `ssh://git@github.com/owner/name`;
    /// nil for any other host, or a path that isn't owner/name.
    static func name(ofRemote url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var path: Substring
        if let scp = trimmed.range(of: "git@github.com:"), scp.lowerBound == trimmed.startIndex {
            path = trimmed[scp.upperBound...]
        } else if let parsed = URLComponents(string: trimmed), let host = parsed.host?.lowercased(),
                  host == "github.com" || host == "www.github.com", ["https", "http", "ssh", "git"].contains(parsed.scheme ?? "") {
            path = Substring(parsed.path)
        } else {
            return nil
        }
        while path.hasPrefix("/") { path = path.dropFirst() }
        while path.hasSuffix("/") { path = path.dropLast() }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let valid = parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) } }
        guard parts.count == 2, valid else { return nil }
        return parts.joined(separator: "/")
    }
}
