// A backend is one agent kind, and everything the server needs of it: how
// to make its process (a chat process, or its own terminal), what it can
// resume, a session's transcript, and its models. The server holds a set
// of backends and never branches on the agent itself — a different set is
// a different set of agents. A host swaps the registry to bring its own.

import Foundation
import Synchronization
import VisorProtocol

public protocol AgentBackend: AnyObject, Sendable {
    /// Which agent this serves.
    var kind: AgentKind { get }
    /// The command-line tool it drives, for availability.
    var tool: String { get }
    /// The models it offers, and whether the tool is installed.
    func catalog() -> AgentCatalog
    /// A chat process for a session; resumes `resume` if given.
    @MainActor func makeProcess(cwd: String, skipPermissions: Bool, resume: String?) -> AgentProcess
    /// The agent's own terminal (a PTY process), for TUI mode; nil where
    /// the agent has no terminal to drive (OpenRouter).
    @MainActor func makeTerminal(cwd: String, skipPermissions: Bool, resume: String?) -> (AgentProcess & TerminalCapable)?
    /// The sessions resumable in this folder.
    func resumable(cwd: String) -> [ResumableSession]
    /// A session's transcript, the newest `limit` rows.
    func transcript(id: String, cwd: String, limit: Int) -> [TranscriptEntry]
    /// Makes the session's history findable where the folder now is; a
    /// no-op where the agent resumes by id regardless of folder.
    func adoptHistory(id: String, cwd: String)
}

public extension AgentBackend {
    /// Installed on the login shell's PATH.
    var available: Bool { ToolPath.resolve(tool) != nil }
    func adoptHistory(id: String, cwd: String) { _ = SessionCatalog.adoptHistory(agent: kind, id: id, cwd: cwd) }
    func resumable(cwd: String) -> [ResumableSession] { SessionCatalog.resumable(agent: kind, cwd: cwd) }
    func transcript(id: String, cwd: String, limit: Int) -> [TranscriptEntry] {
        SessionCatalog.transcript(agent: kind, id: id, cwd: cwd, limit: limit)
    }
    @MainActor func makeTerminal(cwd: String, skipPermissions: Bool, resume: String?) -> (AgentProcess & TerminalCapable)? {
        TerminalProcess(agent: kind, cwd: cwd, skipPermissions: skipPermissions, resume: resume)
    }
}
