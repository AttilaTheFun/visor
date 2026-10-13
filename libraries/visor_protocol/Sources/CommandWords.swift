/// Whether a slash command as an agent's log wrote it is the one the user
/// sent. A log may keep a command its own way — Codex writes a goal back
/// with its line breaks and quotes escaped, and may shorten a long one —
/// so for a command the same command word and the same opening words (the
/// spacing aside) are the same message.
public enum CommandWords {
    /// How much of a command is compared.
    static let opening = 60

    public static func same(_ written: String, _ sent: String) -> Bool {
        let a = normalized(written), b = normalized(sent)
        guard a.hasPrefix("/"), b.hasPrefix("/") else { return false }
        guard a.split(separator: " ").first == b.split(separator: " ").first else { return false }
        return a == b || a.prefix(opening) == b.prefix(opening)
    }

    /// The words alone: escapes undone, every run of spacing one space.
    static func normalized(_ text: String) -> String {
        let unescaped = text.replacing("\\n", with: " ").replacing("\\\"", with: "\"")
        return unescaped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
