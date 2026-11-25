// The Sessions container in the server agent (`Visor --server`,
// docs/containers.md): VisorContainer's engine on Apple's Containerization,
// given to the server as its SessionsContainer. Its settings are the
// server's, resolved for this Mac (its cores, the memory free when it
// starts); its assets and root filesystem on the Visor volume (Containers/),
// Sessions and Sources shared at their paths as volumes.json has them; its
// relay's socket in the data folder's run/ (this user's alone), carried to
// agent-proxy's relay port in this same process with the relay's token from
// the server's secrets; and the driver link's socket beside it, carried to
// this server's driver (agent_protocol's AgentDriver, 127.0.0.1:7434); and
// agent-proxy's authorities' certificates (GitHub's, at agentProxy's
// `caCertificate` or the data folder's `agent-proxy/ca.pem`, and Anthropic's
// beside it), which its guest trusts; and the servers of agent-proxy's MCP
// pass-through, for its Claude (the container's Claude folder on Sessions).
// The sessions placed in it (the server's
// container runner) have their agent-wrappers started in it, and keep it
// from its idle stop.

import DiskVolumes
import Foundation
import Synchronization
import VisorAgentProxyHost
import VisorContainer
import VisorContainerCore
import VisorContainerRunner
import VisorProtocol
import VisorServer

final class MacSessionsContainer: SessionsContainer {
    let engine: ContainerEngine
    /// The server's settings as last told.
    private let settings: KeptSettings

    /// `placed`: how many sessions are placed in it now, whose agents
    /// should run (the server's).
    @MainActor
    init(settings: ServerSettings, placed: @escaping @Sendable () async -> Int) {
        let kept = KeptSettings(settings)
        self.settings = kept
        let data = MacPlaces.data
        let status = MacPlaces.folders.data
        let run = data.appendingPathComponent("run", isDirectory: true)
        // In the app group's container instead, when the sockets go there.
        let group = MacPlaces.groupPlaces
        let volumes = DiskVolumes.locate(dataDirectory: status)
        let sessionsFolder = volumes.sessions.path
        let images = ContainerizationBackend()
        let token = KeptSecret(AgentProxySettings.relayTokenName, in: ServerPlatform.current.secrets)
        let resources = Bundle.main.resourceURL
        let linux = resources?.appendingPathComponent("Linux", isDirectory: true)
        let manifest = ContainerManifest.inResources(resources)
        let proxyPlaces = MacAgentProxy.places
        engine = ContainerEngine(context: ContainerEngine.Context(
            host: .current,
            locate: { try ContainerLayout.locate(DiskVolumes.locate(dataDirectory: status)) },
            linuxPrograms: linux.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil },
            version: VisorMacApp.bundleVersion,
            sessions: volumes.sessions.path,
            relaySocket: group?.relaySocket.map { URL(fileURLWithPath: $0) } ?? run.appendingPathComponent("relay.sock"),
            relayToken: { token.value },
            driverSocket: group?.driverSocket.map { URL(fileURLWithPath: $0) } ?? run.appendingPathComponent("driver.sock"),
            driverPort: MacServer.agentProtocolPort,
            authorities: {
                [kept.current.agentProxy?.caCertificate ?? proxyPlaces.caCertificate, proxyPlaces.anthropicCertificate]
                    .map { URL(fileURLWithPath: $0) }
            },
            assets: images,
            backend: ContainerizationMachines(images: images),
            configuration: {
                Self.configuration(kept.current, manifest: manifest, sources: DiskVolumes.locate(dataDirectory: status).sources.readyPath,
                                   sessions: sessionsFolder)
            },
            placedSessions: placed,
            log: { ServerPlatform.current.log($0) }))
    }

    /// The settings as the engine takes them, for this Mac: the checkouts'
    /// folder the setting's, else the Sources volume when it's mounted
    /// (`sources`), shared at the same path; and agent-proxy's MCP
    /// pass-through's servers for the Claude folder on Sessions (`sessions`).
    static func configuration(_ settings: ServerSettings, manifest: ContainerManifest?, sources: String?,
                              sessions: String) -> ContainerEngineConfiguration {
        let container = settings.container ?? ContainerSettings()
        let info = ProcessInfo.processInfo
        return ContainerEngineConfiguration(
            enabled: container.enabled,
            cpus: container.resolvedCPUs(cores: info.activeProcessorCount),
            memoryGiB: container.resolvedMemoryGiB(availableBytes: HostMemory.availableBytes, physicalBytes: HostMemory.physicalBytes),
            idleMinutes: container.idleMinutes,
            image: ContainerAssets.image(manifest: manifest, override: container.imageDigest),
            relayPort: settings.agentProxy?.relayPort,
            checkouts: container.checkouts ?? sources,
            claudeMCP: ContainerClaudeMCP(folder: VisorServer.containerClaudeFolder(sessions: sessions),
                                          servers: VisorServer.containerMCPServers(settings.agentProxy)))
    }

    func status() async -> ContainerStatus { await engine.status() }

    func start() async -> ContainerStatus { await engine.start() }

    func stop() async -> ContainerStatus { await engine.stop() }

    func restart() async -> ContainerStatus { await engine.restart() }

    var sharedFolders: [String] { engine.sharedFolders(engine.context.configuration()) }

    func startAgent(_ agent: ContainerAgent) async throws -> any ContainerAgentRun { try await engine.startAgent(agent) }

    func run(_ command: ContainerCommand) async throws -> ContainerCommandOutput { try await engine.run(command) }

    @MainActor
    func settingsChanged(_ settings: ServerSettings) {
        let before = self.settings.replace(with: settings)
        // A relay port given (the container turned on): agent-proxy, in
        // this process, listens on it.
        if before.agentProxy != settings.agentProxy { MacAgentProxy.refold(settings.agentProxy) }
        let engine = engine
        Task { await engine.configurationChanged() }
    }

    func loopbackPortIsFree(_ port: Int) -> Bool { LoopbackPort.isFree(port) }
}

/// The server's settings, as the engine reads them from any thread.
private final class KeptSettings: Sendable {
    private let value: Mutex<ServerSettings>

    init(_ settings: ServerSettings) { value = Mutex(settings) }

    var current: ServerSettings { value.withLock { $0 } }

    /// `settings` kept; what was kept before.
    func replace(with settings: ServerSettings) -> ServerSettings {
        value.withLock { held in
            defer { held = settings }
            return held
        }
    }
}
