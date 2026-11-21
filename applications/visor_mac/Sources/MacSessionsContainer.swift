// The Sessions container in the server agent (`Visor --server`,
// docs/containers.md): VisorContainer's engine on Apple's Containerization,
// given to the server as its SessionsContainer. Its settings are the
// server's, resolved for this Mac (its cores, the memory free when it
// starts); its assets and root filesystem on the Containers volume; its
// relay's socket in the data folder's run/ (this user's alone), carried to
// agent-proxy's relay port in this same process with the relay's token from
// the server's secrets; and the driver link's socket beside it, carried to
// this server's driver (agent_protocol's AgentDriver, 127.0.0.1:7434). The
// sessions placed in it (the server's container runner) have their
// agent-wrappers started in it, and keep it from its idle stop.

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
        let data = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Visor")
        let run = data.appendingPathComponent("run", isDirectory: true)
        let images = ContainerizationBackend()
        let token = KeptSecret(AgentProxySettings.relayTokenName, in: ServerPlatform.current.secrets)
        let resources = Bundle.main.resourceURL
        let linux = resources?.appendingPathComponent("Linux", isDirectory: true)
        let manifest = ContainerManifest.inResources(resources)
        engine = ContainerEngine(context: ContainerEngine.Context(
            host: .current,
            locate: { try ContainerLayout.locate(DiskVolumes.locate(dataDirectory: data)) },
            linuxPrograms: linux.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil },
            version: VisorMacApp.bundleVersion,
            relaySocket: run.appendingPathComponent("relay.sock"),
            relayToken: { token.value },
            driverSocket: run.appendingPathComponent("driver.sock"),
            driverPort: MacServer.agentProtocolPort,
            assets: images,
            backend: ContainerizationMachines(images: images),
            configuration: { Self.configuration(kept.current, manifest: manifest) },
            placedSessions: placed,
            log: { ServerPlatform.current.log($0) }))
    }

    /// The settings as the engine takes them, for this Mac.
    static func configuration(_ settings: ServerSettings, manifest: ContainerManifest?) -> ContainerEngineConfiguration {
        let container = settings.container ?? ContainerSettings()
        let info = ProcessInfo.processInfo
        return ContainerEngineConfiguration(
            enabled: container.enabled,
            cpus: container.resolvedCPUs(cores: info.activeProcessorCount),
            memoryGiB: container.resolvedMemoryGiB(availableBytes: HostMemory.availableBytes, physicalBytes: HostMemory.physicalBytes),
            idleMinutes: container.idleMinutes,
            image: ContainerAssets.image(manifest: manifest, override: container.imageDigest),
            relayPort: settings.agentProxy?.relayPort,
            checkouts: container.checkouts)
    }

    func status() async -> ContainerStatus { await engine.status() }

    func start() async -> ContainerStatus { await engine.start() }

    func stop() async -> ContainerStatus { await engine.stop() }

    func restart() async -> ContainerStatus { await engine.restart() }

    var sharedFolders: [String] { engine.sharedFolders(engine.context.configuration()) }

    func startAgent(_ agent: ContainerAgent) async throws -> any ContainerAgentRun { try await engine.startAgent(agent) }

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
