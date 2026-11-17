// A folder for each session (Shireworks' docs/volumes.md: the primary
// container's sessions in its Sessions volume): a server told where its
// sessions live (VISOR_SESSIONS_DIR) gives each new session, and each
// session moved here, a folder of its own there, <dir>/<agent>/<id>, so
// that each agent's conversation and memory, which Claude Code keys by
// the folder, are its own; and the instructions at the folder's root
// (its AGENTS.md) are every session's. A session moved here brings no
// repositories: its agent clones what it needs into its folder.

import Foundation
import VisorProtocol

/// Where a server's sessions work.
public struct SessionFolders: Sendable, Equatable {
    /// The sessions' root: /Volumes/Sessions.
    public var sessions: String

    public init(sessions: String) {
        self.sessions = Self.trimmed(sessions)
    }

    /// The folder of the session `id` of `agent`: <sessions>/Claude/<id>
    /// (the id as SessionPathName names it: itself, for a UUID).
    public func folder(agent: AgentKind, id: String) -> String {
        "\(sessions)/\(Self.name(of: agent))/\(SessionPathName.of(id))"
    }

    /// The agent's part of a session's folder.
    static func name(of agent: AgentKind) -> String {
        switch agent {
        case .claude: "Claude"
        case .codex: "Codex"
        case .openrouter: "OpenRouter"
        }
    }

    private static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
