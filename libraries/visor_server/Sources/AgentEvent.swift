import Foundation
import Synchronization
import VisorProtocol

public enum AgentEvent: Sendable {
    /// More of the reply being written.
    /// Words streamed for the assistant message with this id.
    case delta(message: String, text: String)
    /// What the agent is doing now, or nothing (one line, for a list).
    case activity(String?)
    /// The model is thinking, or has stopped.
    case thinking(Bool)
    /// A tool call began: what it is, for the turn's status; for a task
    /// list tool, the list as written.
    case toolStarted(id: String, name: String, label: String, tasks: [TaskItem]?)
    /// The tool with this id finished.
    case toolFinished(id: String)
    case busy(Bool)
    /// A failure to show under the transcript.
    case failure(String)
    /// The tokens the last request carried, and the model's window: how
    /// full the agent's context is.
    case context(used: Int, limit: Int?)
    /// The agent's own session id, once it has one: where its transcript
    /// file is.
    case session(String)
    /// The slash commands the agent takes, as it lists them.
    case commands([SlashCommand])
    /// The model the agent says it is actually running.
    case model(String)
    /// What the agent's session has used, as the agent's own running
    /// total: which may start over when the agent is launched again.
    case spent(SessionUsage)
    /// How the agent's account is paid for: the plan, in words.
    case plan(String, subscription: Bool)
    /// The account's windows and budgets as they stand.
    case limits([UsageLimit])
    /// What the agent has running in the background, whole, whenever it
    /// changes; empty when it waits on nothing.
    case background([StatusItem])
    /// The goal the agent itself says it works toward (Codex's), or none:
    /// met (`met`), or cleared.
    case goal(String?, met: Bool)
    /// The agent started in another permission mode than the one asked
    /// for (an administrator's policy kept it from auto-approving): the
    /// session is manual from here, and says why.
    case manual(String)
    /// Something to tell the user about the session, in words: the answer
    /// to a command that has no row of its own.
    case notice(String)
    /// How much memory the agent and what it runs are using, as its host
    /// says (nil once it has gone).
    case memory(Int64?)
    /// The agent asks the user something and waits (Codex's
    /// request_user_input): shown as the session's pending approval, with
    /// its questions; the answers go back through `AgentProcess.answer`.
    case question(ApprovalRequest)
}
