import Foundation
import Synchronization
import VisorProtocol

/// The agents the server serves. Injectable: a host assigns its own before
/// the server starts, and every seam — process, terminal, resumable list,
/// transcript, models — goes through whatever is registered here.
public final class AgentHarnesses: Sendable {
    private let byKind: [AgentKind: AgentHarness]
    public let all: [AgentHarness]

    public init(_ list: [AgentHarness]) {
        all = list
        byKind = Dictionary(list.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func harness(for kind: AgentKind) -> AgentHarness? { byKind[kind] }

    /// Claude Code, Codex, and Ori (Claude Code's protocol under another
    /// tool). The set Visor ships with.
    public static let standard = AgentHarnesses([
        ClaudeHarness(kind: .claude, tool: "claude", models: [
            AgentModel(id: "fable", title: "Fable 5.1", subtitle: "The most intelligent model", efforts: ClaudeHarness.efforts),
            AgentModel(id: "opus", title: "Opus 5", subtitle: "Deep reasoning for complex work", efforts: ClaudeHarness.efforts),
            AgentModel(id: "sonnet", title: "Sonnet 5", subtitle: "Fast and capable for everyday tasks", efforts: ClaudeHarness.efforts),
            AgentModel(id: "haiku", title: "Haiku 4.5", subtitle: "The quickest, for light work", efforts: ClaudeHarness.efforts),
        ]),
        CodexHarness(),
        OpenRouterHarness(),
    ])
}
