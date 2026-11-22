// A host an AgentHostSpawner started, as the server sees it while it waits
// for the host to listen.

/// A host started: whether it's still running, while the server waits for
/// it to listen.
@MainActor
package protocol SpawnedAgentHost: AnyObject {
    var isRunning: Bool { get }
}
