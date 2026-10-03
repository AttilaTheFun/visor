#if canImport(Foundation)
import Foundation
#endif

/// What a session runs: a command-line agent, chatted with, or the
/// computer's own shell, typed into on a terminal.
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case openrouter
    /// The login shell of the user the server runs as, on a terminal in
    /// the session's folder: what ssh would give.
    case shell

    public var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .openrouter: "OpenRouter"
        case .shell: "Terminal"
        }
    }

    /// Whether the session is a terminal rather than a chat.
    public var isShell: Bool { self == .shell }

    /// A kind as named on the wire or in a store. A name no longer
    /// offered ("ori", a Claude-protocol harness that OpenRouter replaced)
    /// reads as Claude, so what was kept under it still opens.
    public init?(wire: String) {
        if wire == "ori" { self = .claude } else { self.init(rawValue: wire) }
    }

    public init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        self = AgentKind(wire: name) ?? .claude
    }

    /// The command-line tool.
    public var tool: String { rawValue }
}
