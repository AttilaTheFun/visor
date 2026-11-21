import Foundation

/// Anything that looks like a credential, replaced before text is logged
/// or answered: GitHub's tokens and gh_mcp's own keys.
public enum Redact {
    static let prefixes = ["ghs_", "ghp_", "gho_", "ghu_", "ghr_", "github_pat_", "ghmcp_", "x-access-token:"]

    public static func secrets(in text: String) -> String {
        var result = ""
        var index = text.startIndex
        outer: while index < text.endIndex {
            for prefix in prefixes where text[index...].hasPrefix(prefix) {
                var end = text.index(index, offsetBy: prefix.count)
                while end < text.endIndex, let scalar = text[end].unicodeScalars.first,
                      scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" {
                    end = text.index(after: end)
                }
                if text.distance(from: index, to: end) - prefix.count >= 8 {
                    result += prefix + "[redacted]"
                    index = end
                    continue outer
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    /// One line of at most `limit` characters.
    public static func line(_ text: String, limit: Int = 300) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let clean = secrets(in: first)
        return clean.count > limit ? String(clean.prefix(limit)) + "…" : clean
    }
}
