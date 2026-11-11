// A folder for each session (Shireworks' docs/volumes.md: the primary
// container's sessions in its Sessions volume): a server told where its
// sessions live (VISOR_SESSIONS_DIR) gives each new session, and each
// session moved here, a folder of its own there, <dir>/<agent>/<id>, so
// that each agent's conversation and memory, which Claude Code keys by
// the folder, are its own; and the instructions at the folder's root
// (its AGENTS.md) are every session's. The repositories they work in are
// apart (VISOR_SOURCES_DIR): a moved session's go there by name.

import Foundation
import VisorProtocol

/// Where a server's sessions work, and the repositories with them.
public struct SessionFolders: Sendable, Equatable {
    /// The sessions' root: /Volumes/Sessions.
    public var sessions: String
    /// The repositories': /Volumes/Sources; nil where they aren't kept apart.
    public var sources: String?

    public init(sessions: String, sources: String? = nil) {
        self.sessions = Self.trimmed(sessions)
        self.sources = sources.map(Self.trimmed)
    }

    /// The folder of the session `id` of `agent`: <sessions>/Claude/<id>.
    public func folder(agent: AgentKind, id: String) -> String {
        "\(sessions)/\(Self.name(of: agent))/\(id)"
    }

    /// Where a repository a moved session works in goes here: under the
    /// sources by its own folder's name. Nil without sources, or for a
    /// path with no name.
    public func source(for path: String) -> String? {
        guard let sources else { return nil }
        let name = (Self.trimmed(path) as NSString).lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        return "\(sources)/\(name)"
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
