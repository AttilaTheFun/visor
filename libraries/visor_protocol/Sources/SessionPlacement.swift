// Where a session's agent runs, as its server places it (docs/containers.md,
// "Placing sessions"): on this computer, in this computer's Sessions
// container, or on a runner of the deprecated dispatcher's. Another
// computer is another server, reached by Migrate…, not a placement here.

/// Where a session's agent runs on its server.
public enum SessionPlacement: String, Codable, Hashable, Sendable {
    /// On the computer itself, as Visor's sessions always have.
    case host
    /// In the computer's Sessions container (Visor's own, one per Mac).
    case container
    /// On a runner that claimed it from the dispatcher (deprecated: agent
    /// jobs move to CI).
    case runner
}
