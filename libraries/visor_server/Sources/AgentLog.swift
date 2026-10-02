// Every agent's own log, read the one way: Claude Code's session JSONL,
// Codex's rollout JSONL, and the openrouter CLI's message JSONL are each
// read into lines of the shape Claude's parser gives — a node with the line
// it follows, and what it says — so one indexer, one cache and one
// assembler make every agent's transcript. The log is the transcript: what
// the user sent is no row until the agent's log has it.

import ClaudeTranscript
import Foundation
import VisorProtocol

/// Where each agent keeps a session's log, and how to read it.
enum AgentLog {
    /// The shape a log is written in: which parser reads it.
    enum Format: Sendable {
        case claude, codex, openrouter

        func parser() -> any AgentLogParser {
            switch self {
            case .claude: ClaudeLogParser()
            case .codex: CodexRolloutParser()
            case .openrouter: OpenRouterLogParser()
            }
        }
    }

    static func locate(agent: AgentKind, id: String, cwd: String) -> (url: URL, format: Format)? {
        switch agent {
        case .claude:
            return ClaudeSessionFiles.locate(sessionID: id, cwd: cwd).map { ($0, .claude) }
        case .codex:
            return SessionCatalog.codexRollout(id: id).map { ($0, .codex) }
        case .openrouter:
            let url = SessionCatalog.openrouterRoot.appendingPathComponent("sessions/\(id).jsonl")
            return FileManager.default.fileExists(atPath: url.path) ? (url, .openrouter) : nil
        }
    }
}
