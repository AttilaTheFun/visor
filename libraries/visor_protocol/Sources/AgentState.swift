#if canImport(Foundation)
import Foundation
#endif

/// Where a session's agent is, as its server tells it, and so what may be
/// done with it: a running agent can be stopped or restarted, a stopped
/// one started, and one starting or stopping is left until it gets there.
/// (A session in a virtual machine, to come, has its machine's states.)
public enum AgentState: String, Codable, CaseIterable, Sendable {
    /// Being made: its process starting, after a start or a restart.
    case starting
    /// Takes what it is sent: its process up, or started by the next
    /// message.
    case running
    /// Its process being ended, after a stop or a restart.
    case stopping
    /// Ended by the user, and kept so (a launch of the server too) until
    /// started again: what is sent meanwhile waits in the queue.
    case stopped
}
