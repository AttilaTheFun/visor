// What Visor never hands an agent from its own environment: the admin
// token (VISOR_ADMIN_TOKEN), which is the computer's owner's, never an
// agent's; and, for an agent run on a runner (a container's, or this
// computer's native runner's wrapper), Shireworks' session
// (SHIREWORKS_SESSION) too. A native session's agent may still find the
// admin token where its owner's own shell sets it: Visor never passes it.

/// The variables withheld from agents' environments.
public enum AgentEnvironment {
    /// Never given to any agent Visor starts.
    public static let withheld = ["VISOR_ADMIN_TOKEN"]
    /// Never given to a runner's agent, in a container or not.
    public static let withheldFromRunners = withheld + ["SHIREWORKS_SESSION"]

    /// `environment` as a native session's agent (and what Visor runs for
    /// it) is given it.
    public static func forNativeAgent(_ environment: [String: String]) -> [String: String] {
        environment.filter { !withheld.contains($0.key) }
    }

    /// `environment` as a runner's agent's wrapper is given it.
    public static func forRunnerAgent(_ environment: [String: String]) -> [String: String] {
        environment.filter { !withheldFromRunners.contains($0.key) }
    }
}
