// The Sessions container's engine as the server reaches it
// (docs/containers.md): given by the binary that has one (Visor's
// background server on a Mac, `Visor --server`: its ContainerEngine on
// Apple's Containerization), none elsewhere. The server answers
// `GET /api/container` and `POST /api/container/start|stop` with it, tells
// it of each change of the settings, and gives agent-proxy a relay port
// when the container is turned on.

import VisorProtocol

public protocol SessionsContainer: AnyObject, Sendable {
    /// How it stands now.
    func status() async -> ContainerStatus
    /// Started (with no egress, its check run again); how it stands after.
    func start() async -> ContainerStatus
    /// Stopped; how it stands after.
    func stop() async -> ContainerStatus
    /// The server's settings, changed (or as they are when it's given).
    @MainActor func settingsChanged(_ settings: ServerSettings)
    /// Whether nothing listens on loopback's `port` now: what a relay port
    /// is chosen by.
    func loopbackPortIsFree(_ port: Int) -> Bool
}
