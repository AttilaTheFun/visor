import Foundation

/// A repository's CODEOWNERS, as GitHub reads it (docs/github-gate-rules.md,
/// [M12]): one rule a line, a pattern and its owners, matched as gitignore
/// matches; the last rule that matches a path says who owns it, and a rule
/// with no owners leaves what it matches unowned. A pattern that can't be
/// read is left out, as GitHub leaves it.
struct CodeOwners {
    struct Rule {
        let matcher: NSRegularExpression
        /// It matches folders only (a trailing `/`).
        let foldersOnly: Bool
        let owners: [String]
    }

    let rules: [Rule]

    init(_ text: String) {
        rules = text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let pattern = fields.first, !pattern.hasPrefix("#") else { return nil }
            var owners: [String] = []
            for field in fields.dropFirst() {
                if field.hasPrefix("#") { break }
                if field.hasPrefix("@") || field.contains("@") { owners.append(field) }
            }
            guard let (matcher, foldersOnly) = Self.compile(pattern) else { return nil }
            return Rule(matcher: matcher, foldersOnly: foldersOnly, owners: owners)
        }
    }

    /// Who owns `path`: the owners of the last rule that matches it, or of a
    /// folder above it.
    func owners(of path: String) -> [String] {
        let parts = path.split(separator: "/").map(String.init)
        var candidates: [(String, Bool)] = []
        for index in parts.indices {
            candidates.append((parts[...index].joined(separator: "/"), index < parts.count - 1))
        }
        for rule in rules.reversed() {
            let matches = candidates.contains { candidate, isFolder in
                (isFolder || !rule.foldersOnly)
                    && rule.matcher.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil
            }
            if matches { return rule.owners }
        }
        return []
    }

    /// A pattern as a regular expression for a whole path, and whether it
    /// matches folders only.
    static func compile(_ pattern: String) -> (NSRegularExpression, Bool)? {
        var text = pattern
        let foldersOnly = text.hasSuffix("/") && text.count > 1
        if foldersOnly { text.removeLast() }
        if text.isEmpty || text == "*" || text == "**" || text == "/" || text == "/*" || text == "/**" {
            return (try? NSRegularExpression(pattern: "^.*$")).map { ($0, false) }
        }
        let anchored = text.hasPrefix("/") || text.dropFirst().contains("/")
        if text.hasPrefix("/") { text.removeFirst() }
        var expression = anchored ? "^" : "^(?:.*/)?"
        let characters = Array(text)
        var at = 0
        while at < characters.count {
            let c = characters[at]
            if c == "\\" {
                at += 1
                guard at < characters.count else { return nil }
                expression += NSRegularExpression.escapedPattern(for: String(characters[at]))
            } else if c == "*" {
                if at + 1 < characters.count, characters[at + 1] == "*" {
                    let atStart = at == 0 || characters[at - 1] == "/"
                    let slashAfter = at + 2 < characters.count && characters[at + 2] == "/"
                    if atStart && slashAfter {
                        expression += "(?:.*/)?"
                        at += 3
                        continue
                    }
                    expression += ".*"
                    at += 2
                    continue
                }
                expression += "[^/]*"
            } else if c == "?" {
                expression += "[^/]"
            } else {
                expression += NSRegularExpression.escapedPattern(for: String(c))
            }
            at += 1
        }
        return (try? NSRegularExpression(pattern: expression + "$")).map { ($0, foldersOnly) }
    }
}
