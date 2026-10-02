// An agent as a subprocess: something that takes user turns and yields
// normalised events. Claude Code and Codex differ in how they are driven
// (one long-lived process fed on stdin; one process per turn, resumed by
// id) and in their JSON; each adapter hides that.
//
// A process is driven from the main actor, where the server keeps its
// sessions. What the agent says is read and parsed off it, and reaches
// the server as a stream of events, in the order the agent said them.

import Foundation
import Synchronization
import VisorProtocol

@MainActor
public protocol AgentProcess: AnyObject {
    /// What the agent does, in order. One listener: the session's record.
    var events: AsyncStream<AgentEvent> { get }
    /// Auto (no prompts) or manual; takes effect when the agent next
    /// (re)spawns — Codex each turn, Claude after `stop`.
    var skipPermissions: Bool { get set }
    /// The model and effort flags; nil leaves the provider's default. Take
    /// effect when the agent next (re)spawns, like `skipPermissions`.
    var model: String? { get set }
    var effort: String? { get set }
    /// How the agent reaches the app: the port and the agent-side token,
    /// plus this session's id. The permission shim is given it in manual
    /// mode, and the agent itself always has it in its environment — that
    /// is how a session knows which session it is (VISOR_SESSION) and can
    /// ask the server to restart into it.
    var approvalEnvironment: [String: String] { get set }
    /// The agent's own session id (Claude's session, Codex's thread), once
    /// a turn has started it; what `resumeCommand` and unarchiving use.
    var resumeID: String? { get }
    /// The terminal command that resumes the same session, once known.
    var resumeCommand: String? { get }
    /// Sends a user turn; spawns (or resumes) the process as needed.
    func send(_ text: String) throws
    /// Ends the turn in flight but keeps the process, so the next message
    /// carries straight on in it. Where an agent has no way to end a turn
    /// without ending the process, this is `stop`.
    func interrupt()
    /// Ends the running process — gracefully (stdin closed, a moment to
    /// exit) then by force — without waiting for it; the transcript and
    /// the agent's own session survive, so the next `send` resumes it.
    func stop()
    /// Ends it and returns once it is gone: asked to go, then after
    /// `deadline` made to. What a quitting app waits for (an agent left
    /// behind runs on with nobody at the other end of its pipes), and what
    /// comes before another agent is started on the same session.
    func end(within deadline: Duration) async
    /// The running agent's pid, written down so a later launch can
    /// recognise one of ours that outlived us.
    var processID: Int32? { get }
}

public extension AgentProcess {
    /// Without its own way to end a turn, an interrupt is a stop: the
    /// process goes, and the next message spawns another that resumes.
    func interrupt() { stop() }
}
