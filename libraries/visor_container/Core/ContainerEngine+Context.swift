// What the container engine is given by the server that runs it: this Mac,
// where the Containers volume is, Visor's Linux programs, the relay's
// socket and token, the driver link's socket and the driver's port, the backends, the settings as they are now, how many
// sessions are placed in the container, the clock and the log.

import Foundation

extension ContainerEngine {
    public struct Context: Sendable {
        public var host: ContainerHost
        /// Visor's folder on the Containers volume (ContainerLayout.locate),
        /// or why there is none.
        public var locate: @Sendable () throws -> ContainerLayout
        /// The app's Contents/Resources/Linux; nil for a build without them.
        public var linuxPrograms: URL?
        /// Visor's version, naming the programs' folder on the volume.
        public var version: String
        /// The Sessions volume, shared at the same path.
        public var sessions: String
        /// The relay's socket on the host (under 104 bytes, in a folder of
        /// this user's alone).
        public var relaySocket: URL
        /// The relay's token as it is now (agent-proxy/relay-token).
        public var relayToken: @Sendable () -> String?
        /// The driver link's socket on the host (beside the relay's unless
        /// given: the same folder, this user's alone).
        public var driverSocket: URL
        /// Visor's driver (agent_protocol's AgentDriver) on this Mac's
        /// loopback: 7434, unless a test runs its own.
        public var driverPort: Int
        public var assets: any ContainerAssetBackend
        /// The kernel and init filesystem pinned (the build's; a test's own).
        public var pins: ContainerPins
        public var backend: any ContainerBackend
        /// The settings as they are now.
        public var configuration: @Sendable () -> ContainerEngineConfiguration
        /// The sessions placed in the container (step 4's): it isn't idle
        /// while there are any, and a server's start starts it for them.
        public var placedSessions: @Sendable () async -> Int
        public var now: @Sendable () -> Date
        public var log: @Sendable (String) -> Void
        /// How long the egress check may take, each try.
        public var checkTimeout: Duration
        /// The pause between the egress check's tries.
        public var checkRetryPause: Duration

        public init(host: ContainerHost, locate: @escaping @Sendable () throws -> ContainerLayout, linuxPrograms: URL?, version: String,
                    sessions: String = "/Volumes/Sessions", relaySocket: URL, relayToken: @escaping @Sendable () -> String?,
                    driverSocket: URL? = nil, driverPort: Int = 7434, assets: any ContainerAssetBackend, pins: ContainerPins = .current, backend: any ContainerBackend,
                    configuration: @escaping @Sendable () -> ContainerEngineConfiguration,
                    placedSessions: @escaping @Sendable () async -> Int = { 0 }, now: @escaping @Sendable () -> Date = { Date() },
                    log: @escaping @Sendable (String) -> Void = { _ in }, checkTimeout: Duration = .seconds(20),
                    checkRetryPause: Duration = .seconds(2)) {
            self.host = host
            self.locate = locate
            self.linuxPrograms = linuxPrograms
            self.version = version
            self.sessions = sessions
            self.relaySocket = relaySocket
            self.relayToken = relayToken
            self.driverSocket = driverSocket ?? relaySocket.deletingLastPathComponent().appendingPathComponent("driver.sock")
            self.driverPort = driverPort
            self.assets = assets
            self.pins = pins
            self.backend = backend
            self.configuration = configuration
            self.placedSessions = placedSessions
            self.now = now
            self.log = log
            self.checkTimeout = checkTimeout
            self.checkRetryPause = checkRetryPause
        }
    }
}
