// The Claude credential the Sessions container's agents reach Anthropic with
// (docs/containers.md, "Claude's credential"): a `claude setup-token` token
// (`sk-ant-oat…`), made on the Mac, pasted into Settings › Sessions
// Container, and kept as agent-proxy's secret, which attaches it to each
// request to api.anthropic.com. The containers never see it: their agents
// have `CLAUDE_CODE_OAUTH_TOKEN` set to a placeholder the proxy replaces.

import Foundation

public enum ClaudeCredential {
    /// What every `claude setup-token` token begins with.
    public static let prefix = "sk-ant-oat"
    /// The placeholder the container's agents have for one.
    public static let placeholder = "visor-agent-proxy"

    /// Why `token` (trimmed) isn't one to keep, or nil: loosely, its shape
    /// alone, one line that begins as setup-token's do.
    public static func problem(_ token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Paste the token `claude setup-token` printed." }
        guard trimmed.hasPrefix(prefix), !trimmed.contains(where: { $0.isWhitespace }), trimmed.count <= 4096 else {
            return "That isn't a `claude setup-token` token: one begins with \(prefix)."
        }
        return nil
    }
}
