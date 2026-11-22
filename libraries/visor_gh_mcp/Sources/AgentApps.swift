import Foundation

/// The agents gh_mcp acts as: each a GitHub App of its own
/// (logan-shire-claude, -codex, -agent), whose installation tokens
/// `agent-token token <agent>` gives, `<agent>` the app's last word
/// (claude, codex or agent), as gh_mcp named it. Visor's settings may name
/// an app either way.
public enum AgentApps {
    /// The agents, as agent-token takes them.
    public static let known = ["claude", "codex", "agent"]
    /// What every app's name starts with.
    public static let prefix = "logan-shire-"

    /// `logan-shire-claude` or `claude`: `claude`, as agent-token takes it;
    /// nil for any other.
    public static func agent(_ given: String) -> String? {
        let name = given.hasPrefix(prefix) ? String(given.dropFirst(prefix.count)) : given
        return known.contains(name) ? name : nil
    }
}
