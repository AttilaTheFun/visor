import Foundation

/// The repository's CODEOWNERS, as pr_merge reads it: a pull request that
/// touches an owned path merges only once an owner approved its head.
/// Logan (2026-10-31): agents merge their own pull requests when CI is
/// green "provided they don't touch protected files"; CODEOWNERS names
/// those files and him as their owner. GitHub enforces it only where branch
/// protection can (a private repository needs a paid plan), so gh_mcp
/// checks it itself, everywhere.
struct CodeOwners: Sendable {
    struct Rule: Sendable {
        let pattern: String
        let owners: [String]
        let regex: NSRegularExpression
        let directoryOnly: Bool
    }

    let rules: [Rule]

    /// GitHub's places, in the order it looks.
    static let paths = [".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS"]

    /// One rule a line: a pattern and its owners (`@user`, `@org/team` or an
    /// email); blank lines and comments skipped. A pattern with no owners
    /// leaves what it matches unowned (the last matching rule wins).
    init(_ text: String) {
        var rules: [Rule] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            var fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            let pattern = fields.removeFirst()
            let owners = fields.prefix { !$0.hasPrefix("#") }.filter { $0.hasPrefix("@") || $0.contains("@") }
            if let (regex, directoryOnly) = Self.compile(pattern) {
                rules.append(Rule(pattern: pattern, owners: owners, regex: regex, directoryOnly: directoryOnly))
            }
        }
        self.rules = rules
    }

    /// The owners of `path` (a file, relative to the root): the last rule
    /// matching it or a folder holding it; none if no rule does.
    func owners(of path: String) -> [String] {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return [] }
        // The file, and every folder above it (a rule for a folder owns
        // what is in it).
        var folders: [String] = []
        for end in 1..<parts.count { folders.append(parts[..<end].joined(separator: "/")) }
        let file = parts.joined(separator: "/")
        var found: [String] = []
        for rule in rules {
            let candidates = rule.directoryOnly ? folders : folders + [file]
            if candidates.contains(where: { Self.matches(rule.regex, $0) }) { found = rule.owners }
        }
        return found
    }

    static func matches(_ regex: NSRegularExpression, _ string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }

    /// gitignore's rules as CODEOWNERS uses them: a leading or inner `/`
    /// anchors at the root (else any depth), a trailing `/` matches folders
    /// only, `*` and `?` stay within a name, `**` crosses folders.
    static func compile(_ pattern: String) -> (NSRegularExpression, Bool)? {
        var body = pattern
        let directoryOnly = body.hasSuffix("/")
        while body.hasSuffix("/") { body.removeLast() }
        let anchored = body.hasPrefix("/") || body.dropFirst().contains("/")
        while body.hasPrefix("/") { body.removeFirst() }
        if body.isEmpty || body == "*" || body == "**" {
            // Everything (`*`, `/`): every file and folder.
            guard let everything = try? NSRegularExpression(pattern: "^.+$") else { return nil }
            return (everything, false)
        }
        var expression = ""
        let characters = Array(body)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "*" {
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    let followedBySlash = index + 2 < characters.count && characters[index + 2] == "/"
                    expression += followedBySlash ? "(?:.*/)?" : ".*"
                    index += followedBySlash ? 3 : 2
                    continue
                }
                expression += "[^/]*"
            } else if character == "?" {
                expression += "[^/]"
            } else if character == "\\", index + 1 < characters.count {
                index += 1
                expression += NSRegularExpression.escapedPattern(for: String(characters[index]))
            } else {
                expression += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        let full = (anchored ? "^" : "^(?:.*/)?") + expression + "$"
        guard let regex = try? NSRegularExpression(pattern: full) else { return nil }
        return (regex, directoryOnly)
    }
}
