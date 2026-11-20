// The check after Super Compact's final step: does HANDOFF.md mention
// every rule and decision the merged ledger holds? A simple key-phrase
// check, not a judgement: each of the ledger's "Rules and decisions"
// bullets is reduced to its telling words (and any identifiers, such as
// `#474` or `0.64`), and one whose identifiers are not all in the
// handoff, or of whose words fewer than half are, is named in a warning
// for the person reviewing it.

import Foundation

enum SuperCompactCheck {
    /// The share of a rule's telling words the handoff must hold.
    static let coverage = 0.5

    /// Words too common to tell one rule from another.
    static let common: Set<String> = [
        "about", "after", "again", "also", "always", "because", "before", "being", "between", "could", "does", "doesn't", "done",
        "each", "every", "first", "from", "have", "into", "it's", "just", "keep", "kept", "like", "make", "more", "must", "never",
        "only", "other", "over", "should", "some", "than", "that", "their", "them", "then", "there", "these", "they", "this",
        "those", "through", "under", "until", "used", "want", "wants", "were", "what", "when", "where", "which", "while", "will",
        "with", "without", "would", "your", "logan", "person", "said", "says", "rule", "decision", "decided",
    ]

    /// The warnings for `handoff` against `ledger`: none when every rule
    /// and decision is mentioned (or the ledger has none).
    static func warnings(ledger: String, handoff: String) -> [String] {
        let rules = rulesAndDecisions(in: ledger)
        guard !rules.isEmpty else { return [] }
        let text = handoff.lowercased()
        let words = Set(tokens(text))
        let missing = rules.filter { !mentioned($0, in: text, words: words) }
        guard !missing.isEmpty else { return [] }
        let listed = missing.prefix(10).map { "“" + SuperCompactFilter.oneLine($0, 160) + "”" }.joined(separator: "; ")
        let more = missing.count > 10 ? " (and \(missing.count - 10) more)" : ""
        return ["HANDOFF.md may leave out \(missing.count) of the ledger's \(rules.count) rules and decisions: \(listed)\(more)"]
    }

    /// The bullets of the ledger's "Rules and decisions" section, each
    /// with the lines that continue it.
    static func rulesAndDecisions(in ledger: String) -> [String] {
        var rules: [String] = []
        var inside = false
        for line in ledger.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                inside = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased().hasPrefix("rules and decisions")
                continue
            }
            guard inside, !trimmed.isEmpty else { continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                rules.append(String(trimmed.dropFirst(2)))
            } else if !rules.isEmpty {
                rules[rules.count - 1] += " " + trimmed
            }
        }
        return rules
    }

    /// Whether a rule is in the handoff: its identifiers all are, and at
    /// least `coverage` of its telling words.
    static func mentioned(_ rule: String, in text: String, words: Set<String>) -> Bool {
        let undated = rule.replacingOccurrences(of: #"^\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
        let ruleTokens = tokens(undated.lowercased())
        let identifiers = Set(ruleTokens.filter { $0.contains { $0.isNumber } && $0.count >= 2 })
        guard identifiers.allSatisfy({ words.contains($0) || text.contains($0) }) else { return false }
        let telling = Set(ruleTokens.filter { $0.count >= 4 && !common.contains($0) && !identifiers.contains($0) })
        guard !telling.isEmpty else { return true }
        let found = telling.filter { words.contains($0) }.count
        return Double(found) >= coverage * Double(telling.count)
    }

    /// Lower-cased words and identifiers: letters, digits and the marks
    /// inside an identifier (`#474`, `0.64`, `super-compact`, `it's`).
    static func tokens(_ text: String) -> [String] {
        let inner: Set<Character> = ["#", ".", "-", "_", "/", "'"]
        var out: [String] = []
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber || (!current.isEmpty && inner.contains(character)) {
                current.append(character)
            } else if !current.isEmpty {
                out.append(current.trimmingCharacters(in: CharacterSet(charactersIn: ".-_/'")))
                current = ""
            } else if character == "#" {
                current = "#"
            }
        }
        if !current.isEmpty { out.append(current.trimmingCharacters(in: CharacterSet(charactersIn: ".-_/'"))) }
        return out.filter { !$0.isEmpty && $0 != "#" }
    }
}
