// The Sessions container's engine as the server reaches it
// (docs/containers.md): given by the binary that has one (Visor's
// background server on a Mac, `Visor --server`: its ContainerEngine on
// Apple's Containerization), none elsewhere. The server answers
// `GET /api/container` and `POST /api/container/start|stop|restart` with
// it, tells it of each change of the settings, gives agent-proxy a relay
// port when the container is turned on, and runs the agents of the
// sessions placed in it there (the container runner, VisorServer+ContainerRunner).

import VisorProtocol

public protocol SessionsContainer: AnyObject, Sendable {
    /// How it stands now.
    func status() async -> ContainerStatus
    /// Started (with no egress, its check run again); how it stands after.
    func start() async -> ContainerStatus
    /// Stopped, and held so (its sessions' agents wait for Start Agent);
    /// how it stands after.
    func stop() async -> ContainerStatus
    /// Stopped and started again, taking a new image if one is pinned;
    /// how it stands after.
    func restart() async -> ContainerStatus
    /// The folders it shares at the same path: the Sessions volume first,
    /// then the checkouts' folder if one is set. A session working under
    /// one keeps its folder when it moves in.
    var sharedFolders: [String] { get }
    /// A session's agent-wrapper started in it (started first if it isn't
    /// running); refused while it's off or has no egress.
    func startAgent(_ agent: ContainerAgent) async throws -> any ContainerAgentRun
    /// The server's settings, changed (or as they are when it's given).
    @MainActor func settingsChanged(_ settings: ServerSettings)
    /// Whether nothing listens on loopback's `port` now: what a relay port
    /// is chosen by.
    func loopbackPortIsFree(_ port: Int) -> Bool
}
