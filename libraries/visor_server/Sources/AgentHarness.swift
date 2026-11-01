// A harness is one kind of session, and everything the server needs of
// it: how to make its agent's process, what it can resume, a session's
// transcript, and its models. The server holds a set of harnesses and
// never branches on the kind itself — a different set is a different set
// of kinds. A host swaps the registry to bring its own.

import Foundation
import Synchronization
import VisorProtocol

public protocol AgentHarness: AnyObject, Sendable {
    /// Which kind of session this serves.
    var kind: AgentKind { get }
    /// The command-line tool it drives, for availability.
    var tool: String { get }
    /// The models it offers, and whether the tool is installed.
    func catalog() -> AgentCatalog
    /// The process for a session; resumes `resume` if given.
    @MainActor func makeProcess(cwd: String, skipPermissions: Bool, resume: String?) -> AgentProcess
    /// The sessions resumable in this folder.
    func resumable(cwd: String) -> [ResumableSession]
    /// A session's transcript, the newest `limit` rows.
    func transcript(id: String, cwd: String, limit: Int) -> [TranscriptEntry]
    /// Makes the session's history findable where the folder now is; a
    /// no-op where the agent resumes by id regardless of folder.
    func adoptHistory(id: String, cwd: String)
    /// The slash commands its sessions take before the agent has listed
    /// its own (or where it lists none): the harness's.
    var commands: [SlashCommand] { get }
    /// The account as the agent says it now, asked outright rather than
    /// heard from a session's turns; nil where it cannot be asked.
    func readAccount() async -> AgentAccount?
    /// Where a branch made at a row of the agent's conversation `id` goes
    /// on from, as the agent's process takes it (`AgentProcess.fork(at:)`);
    /// nil where the agent cannot branch from a row.
    func forkPoint(row: String, id: String, cwd: String) -> String?
    /// The subagents the agent's conversation `id` sent off, oldest first;
    /// none where the agent keeps none apart.
    func subagents(id: String, cwd: String) -> [SubagentInfo]
    /// Whether the agent's list of what runs in the background
    /// (`AgentEvent.background`) has its subagents on it, by the ids
    /// `subagents` gives them: one its files leave unfinished but the list
    /// no longer has ended without saying so.
    var listsSubagentsInBackground: Bool { get }
    /// One subagent's conversation, as rows.
    func subagentTranscript(id: String, cwd: String, subagent: String) -> [TranscriptEntry]
    /// A finished subagent's conversation made one of the agent's own:
    /// the id it resumes by, or nil where the agent cannot.
    func continueSubagent(id: String, cwd: String, subagent: String) -> String?
    /// What the session's agent is handed to pass on to one of its
    /// subagents while it runs: the person's `words`, and how.
    func wordsForSubagent(_ words: String, to subagent: SubagentInfo) -> String
}

public extension AgentHarness {
    /// Installed on the login shell's PATH.
    var available: Bool { ToolPath.resolve(tool) != nil }
    var commands: [SlashCommand] { [] }
    func readAccount() async -> AgentAccount? { nil }
    func forkPoint(row: String, id: String, cwd: String) -> String? { nil }
    func subagents(id: String, cwd: String) -> [SubagentInfo] { [] }
    var listsSubagentsInBackground: Bool { false }
    func subagentTranscript(id: String, cwd: String, subagent: String) -> [TranscriptEntry] { [] }
    func continueSubagent(id: String, cwd: String, subagent: String) -> String? { nil }
    /// Claude Code's way: its SendMessage, by the subagent's id.
    func wordsForSubagent(_ words: String, to subagent: SubagentInfo) -> String {
        let named = subagent.description.isEmpty ? "your subagent" : "your subagent \u{201C}\(subagent.description)\u{201D}"
        return "For \(named) (agent id \(subagent.id)), from me: pass this on to it with SendMessage, as it is, and go on with what you were doing.\n\n\(words)"
    }
    func adoptHistory(id: String, cwd: String) { _ = SessionCatalog.adoptHistory(agent: kind, id: id, cwd: cwd) }
    func resumable(cwd: String) -> [ResumableSession] { SessionCatalog.resumable(agent: kind, cwd: cwd) }
    func transcript(id: String, cwd: String, limit: Int) -> [TranscriptEntry] {
        SessionCatalog.transcript(agent: kind, id: id, cwd: cwd, limit: limit)
    }
}
