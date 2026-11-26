// Settings' Sessions container section (docs/containers.md): its switch,
// its CPUs and memory (the default, or a number within this Mac's, as the
// server's `containerLimits` say: taken at its next start, which the
// section says), the readiness row under them — this Mac (macOS 26 or later, Apple silicon,
// virtualization), the Visor volume, and the assets on it — and the
// container as the server's engine has it (`GET /api/container`: its state,
// CPUs and memory, image, egress check and errors), with Start and Stop;
// and whether its agents' Claude credential is set (agent-proxy's: its
// presence alone), with Sign In to Claude… and Sign Out (docs/containers.md,
// "Claude's credential").
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
import VisorUI

@MainActor
struct ContainerSettingsSection: View {
    var settings: ServerControls.Settings
    /// What the CPUs and memory may be set to on this Mac; nil from a
    /// server that doesn't say, which shows no pickers.
    var limits: ServerControls.ContainerLimits?
    var client: VisorAgentServer
    var send: (ServerControlsChange) -> Void
    @State private var readiness: ContainerReadiness?
    @State private var image: ImageDigest?
    @State private var status: ContainerStatus?
    @State private var problem: String?
    @State private var busy = false
    @State private var signingIn = false

    var body: some View {
        Section {
            let readiness = readiness ?? Self.look(override: settings.containerImageDigest).readiness
            Toggle("Run sessions in a container", isOn: Binding(get: { readiness.isEnabled(setting: settings.containerEnabled) },
                                                                set: { send(ServerControlsChange(containerEnabled: $0)) }))
                .disabled(!readiness.canEnable)
            resourcesRows
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
            claudeRow
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

    /// Its CPUs and memory: the default, or a number within this Mac's,
    /// each sent as it's picked; and when they're taken.
    @ViewBuilder private var resourcesRows: some View {
        if let limits {
            Picker("CPUs", selection: Binding(get: { settings.containerCPUs }, set: { cpus in
                send(ServerControlsChange(containerCPUs: cpus.map(ServerControlsChange.Amount.to) ?? .byDefault))
            })) {
                Text("Default (\(limits.defaultCPUs))").tag(Int?.none)
                ForEach(Self.choices(limits.minimumCPUs, limits.maximumCPUs, set: settings.containerCPUs), id: \.self) { cpus in
                    Text("\(cpus)").tag(Int?.some(cpus))
                }
            }
            .accessibilityIdentifier("container-cpus")
            Picker("Memory", selection: Binding(get: { settings.containerMemoryGiB }, set: { gib in
                send(ServerControlsChange(containerMemoryGiB: gib.map(ServerControlsChange.Amount.to) ?? .byDefault))
            })) {
                Text("Default (half of what's free at its start, \(limits.minimumMemoryGiB)–\(limits.defaultMemoryCapGiB) GiB)")
                    .tag(Int?.none)
                ForEach(Self.choices(limits.minimumMemoryGiB, limits.maximumMemoryGiB, set: settings.containerMemoryGiB),
                        id: \.self) { gib in
                    Text("\(gib) GiB").tag(Int?.some(gib))
                }
            }
            .accessibilityIdentifier("container-memory")
            Text(resourcesNote).font(.caption).foregroundColor(.secondary)
        }
    }

    /// What a picker offers: `least` to `most` (none where `most` is less),
    /// and what's set if the settings file holds another.
    static func choices(_ least: Int, _ most: Int, set: Int?) -> [Int] {
        var choices = most >= least ? Array(least...most) : []
        if let set, !choices.contains(set) { choices = (choices + [set]).sorted() }
        return choices
    }

    /// When new CPUs and memory are taken, and what the running container
    /// has until then.
    private var resourcesNote: String {
        let note = "CPUs and memory apply at the container's next start: after its idle stop, or Stop and Start. "
            + "Visor doesn't restart it for them."
        guard let status, status.state == .running || status.state == .noEgress, let cpus = status.cpus,
              let memory = status.memoryGiB else { return note }
        let changed = (settings.containerCPUs ?? cpus) != cpus || (settings.containerMemoryGiB ?? memory) != memory
        return changed ? note + " It runs with \(cpus) CPUs and \(memory) GiB until then." : note
    }

    /// Whether the container's agents have a Claude credential (agent-proxy's),
    /// with Sign In to Claude… and Sign Out.
    @ViewBuilder private var claudeRow: some View {
        if let set = status?.claudeCredential {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: set ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundColor(set ? .green : .secondary)
                VStack(alignment: .leading) {
                    Text("Claude sign-in")
                    Text(set ? "Set: agent-proxy adds it to the container's requests to Claude; the container never sees it."
                             : "Not set: the container's agents can't reach Claude.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Sign In to Claude…") { signingIn = true }
                    .accessibilityIdentifier("container-sign-in")
                if set {
                    Button("Sign Out") { act { try await client.setContainerClaudeCredential(nil) } }
                        .disabled(busy)
                        .accessibilityIdentifier("container-claude-sign-out")
                }
            }
            .sheet(isPresented: $signingIn) {
                ClaudeCredentialSheet(computer: "this Mac") { token in
                    status = try await client.setContainerClaudeCredential(token)
                }
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
