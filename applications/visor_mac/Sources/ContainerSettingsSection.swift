// Settings' Sessions container section (docs/containers.md): its switch,
// the readiness row under it — this Mac (macOS 26 or later, Apple silicon,
// virtualization), the Visor volume, and the assets on it — and the
// container as the server's engine has it (`GET /api/container`: its state,
// CPUs and memory, image, egress check and errors), with Start and Stop.
// The switch is off, and can't be turned on, unless this Mac can run it.
// The readiness is read here, as files and this Mac's own facts: nothing is
// fetched (the container engine does that when it first starts).

import DiskVolumes
import Foundation
import SwiftUI
import VisorClient
import VisorContainer
import VisorContainerCore
import VisorProtocol

@MainActor
struct ContainerSettingsSection: View {
    var settings: ServerControls.Settings
    var client: VisorAgentServer
    var send: (ServerControlsChange) -> Void
    @State private var readiness: ContainerReadiness?
    @State private var image: ImageDigest?
    @State private var status: ContainerStatus?
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        Section {
            let readiness = readiness ?? Self.look(override: settings.containerImageDigest).readiness
            Toggle("Run sessions in a container", isOn: Binding(get: { readiness.isEnabled(setting: settings.containerEnabled) },
                                                                set: { send(ServerControlsChange(containerEnabled: $0)) }))
                .disabled(!readiness.canEnable)
            ForEach(readiness.checks) { check in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundColor(check.ok ? .green : .secondary)
                    VStack(alignment: .leading) {
                        Text(check.name)
                        Text(check.detail).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            Text(imageLine)
                .font(.caption).foregroundColor(.secondary)
                .textSelection(.enabled)
            statusRow
        } header: {
            Text("Sessions Container")
        }
        .task(id: settings.containerImageDigest) {
            let look = Self.look(override: settings.containerImageDigest)
            readiness = look.readiness
            image = look.image
        }
        .task(id: settings.containerEnabled) {
            // While Settings is open, as the server's engine has it.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(status?.state == .starting ? 2 : 10))
            }
        }
    }

    /// The container as the engine has it, with Start and Stop.
    @ViewBuilder private var statusRow: some View {
        if let status {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: Self.symbol(status.state)).foregroundColor(status.state == .running ? .green : .secondary)
                VStack(alignment: .leading) {
                    Text(status.state.label)
                    Text(Self.detail(status)).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                    if let egress = status.egress { Text(egress).font(.caption).foregroundColor(.secondary).textSelection(.enabled) }
                    ForEach(Array(status.errors.enumerated()), id: \.offset) { _, error in
                        Text(error).font(.caption).foregroundColor(.red).textSelection(.enabled)
                    }
                }
                Spacer()
                if status.state == .running || status.state == .noEgress || status.state == .starting {
                    Button("Stop") { act { try await client.stopContainer() } }.disabled(busy || status.state == .starting)
                }
                if status.state == .stopped || status.state == .noEgress {
                    Button(status.state == .noEgress ? "Check Again" : "Start") { act { try await client.startContainer() } }.disabled(busy)
                }
            }
        }
        if let problem { Text(problem).font(.caption).foregroundColor(.red) }
    }

    private func refresh() async {
        do {
            status = try await client.containerStatus()
            problem = nil
        } catch {
            problem = VisorAgentServer.problem(error)
        }
    }

    private func act(_ call: @escaping () async throws -> ContainerStatus) {
        busy = true
        Task {
            do {
                status = try await call()
                problem = nil
            } catch {
                problem = VisorAgentServer.problem(error)
            }
            busy = false
        }
    }

    static func symbol(_ state: ContainerState) -> String {
        switch state {
        case .running: "shippingbox.fill"
        case .starting: "hourglass"
        case .noEgress: "exclamationmark.triangle"
        case .stopped, .off: "shippingbox"
        }
    }

    /// Its resources, image and processes, a line.
    static func detail(_ status: ContainerStatus) -> String {
        var parts: [String] = []
        if let cpus = status.cpus, let memory = status.memoryGiB { parts.append("\(cpus) CPUs, \(memory) GiB") }
        if let image = status.image.flatMap({ ImageDigest($0) }) { parts.append("image \(image.short)") }
        if status.state == .running { parts.append("\(status.processes) process\(status.processes == 1 ? "" : "es")") }
        if let port = status.relayPort { parts.append("relay port \(port)") }
        if let minutes = status.idleMinutes { parts.append("stops after \(minutes) idle minutes") }
        return parts.joined(separator: " · ")
    }

    private var imageLine: String {
        guard let image else { return "No agent image pinned: this build has no container.json, and the settings name no image digest." }
        let from = settings.containerImageDigest.isEmpty ? "this release's" : "the settings' (containerImageDigest)"
        return "Image \(image.reference()), \(from)."
    }

    /// This Mac's readiness, and the image it would run.
    static func look(override: String) -> (readiness: ContainerReadiness, image: ImageDigest?) {
        let volumes = DiskVolumes.locate(dataDirectory: MacPlaces.folders.data)
        let image = ContainerAssets.image(manifest: ContainerManifest.inResources(Bundle.main.resourceURL),
                                          override: override.isEmpty ? nil : override)
        let assets = (try? ContainerLayout.locate(volumes)).map {
            ContainerAssets(layout: $0, image: image, backend: ContainerizationBackend()).status()
        }
        return (ContainerReadiness(host: .current, volume: volumes.visor, assets: assets), image)
    }
}
