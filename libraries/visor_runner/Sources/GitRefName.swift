/// Git's rules for a ref's name (`git check-ref-format`), as gh_mcp checks a
/// branch's (docs/github-gate-rules.md, Rules:124-137).
enum GitRefName {
    /// Whether `name` (a branch's, without `refs/heads/`) is one git takes.
    static func isBranch(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255, name != "HEAD", name != "@" else { return false }
        if name.hasPrefix("/") || name.hasSuffix("/") || name.hasSuffix(".") || name.hasSuffix(".lock") { return false }
        if name.contains("..") || name.contains("//") || name.contains("@{") { return false }
        for scalar in name.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { return false }
            if " ~^:?*[\\".unicodeScalars.contains(scalar) { return false }
        }
        return !name.split(separator: "/").contains { $0.hasPrefix(".") || $0.hasSuffix(".lock") }
    }

    /// Whether `text` is a commit's id: 40 or 64 hex digits.
    static func isSHA(_ text: String) -> Bool {
        (text.count == 40 || text.count == 64) && text.allSatisfy(\.isHexDigit)
    }
}
