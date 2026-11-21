// The Sessions container in the server agent (`Visor --server`,
// docs/containers.md): VisorContainer's engine on Apple's Containerization,
// given to the server as its SessionsContainer. Its settings are the
// server's, resolved for this Mac (its cores, the memory free when it
// starts); its assets and root filesystem on the Containers volume; its
// relay's socket in the data folder's run/ (this user's alone), carried to
// agent-proxy's relay port in this same process with the relay's token from
// the server's secrets. No session is placed in it yet (step 4).

import DiskVolumes
import Foundation
import Synchronization
import VisorAgentProxyHost
import VisorContainer
import VisorContainerCore
import VisorProtocol
import VisorServer

final class MacSessionsContainer: SessionsContainer {
    let engine: ContainerEngine
    /// The server's settings as last told.
    private let settings: Mutex<ServerSettings>

    @MainActor
    init(settings: ServerSettings) {
        let kept = Mutex(settings)
        self.settings = kept
        let data = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Visor")
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
            relaySocket: data.appendingPathComponent("run", isDirectory: true).appendingPathComponent("relay.sock"),
            relayToken: { token.value },
            assets: images,
            backend: ContainerizationMachines(images: images),
            configuration: { Self.configuration(kept.withLock { $0 }, manifest: manifest) },
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

    @MainActor
    func settingsChanged(_ settings: ServerSettings) {
        let before = self.settings.withLock { held -> ServerSettings in
            defer { held = settings }
            return held
        }
        // A relay port given (the container turned on): agent-proxy, in
        // this process, listens on it.
        if before.agentProxy != settings.agentProxy { MacAgentProxy.refold(settings.agentProxy) }
        let engine = engine
        Task { await engine.configurationChanged() }
    }

    func loopbackPortIsFree(_ port: Int) -> Bool { LoopbackPort.isFree(port) }
}
