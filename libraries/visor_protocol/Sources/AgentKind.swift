#if canImport(Foundation)
import Foundation
#endif

/// What a session runs: a command-line agent, chatted with.
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case openrouter

    public var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .openrouter: "OpenRouter"
        }
    }

    /// A kind as named on the wire or in a store. A name no longer
    /// offered ("ori", a Claude-protocol harness that OpenRouter replaced)
    /// reads as Claude, so what was kept under it still opens. Any other
    /// name is none: a list read off the wire leaves out what it names
    /// ("shell", the terminal sessions of a server of 0.31 or before).
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
