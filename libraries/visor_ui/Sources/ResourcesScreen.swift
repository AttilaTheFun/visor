import SwiftUI
import VisorClient
import VisorProtocol

/// What a computer is using, and for whom: its processors and memory, each
/// of its sessions' containers, and the machines its sessions lease from
/// oss (with oss's computer, where oss says). Opened from a session's row
/// (its container's mark, its machines); asked again every few seconds
/// while it is open.
@MainActor
struct ResourcesScreen: View {
    let host: AgentServerConnection
    @State private var resources: ServerResources?
    @State private var asked = false

    /// How often the computer is asked again.
    static let interval: UInt64 = 3_000_000_000

    var body: some View {
        Form {
            if let resources {
                if let computer = resources.host {
                    Section("This Computer") {
                        ResourceRow(title: computer.name ?? host.record.name, cpus: computer.cpus, cpuPercent: computer.cpuPercent,
                                    memoryLimit: computer.memoryBytes, memoryUsed: computer.memoryUsedBytes)
                    }
                }
                Section {
                    if resources.containers.isEmpty {
                        Text("No containers running.").foregroundStyle(.secondary)
                    }
                    ForEach(resources.containers, id: \.id) { container in
                        ResourceRow(title: title(of: container.session) ?? container.id, subtitle: "Container", mark: "shippingbox",
                                    cpus: container.cpus, cpuPercent: container.cpuPercent,
                                    memoryLimit: container.memoryLimitBytes, memoryUsed: container.memoryUsedBytes)
                    }
                } header: {
                    Text("Containers")
                } footer: {
                    if let warning = Self.overcommitted(resources) { Text(warning) }
                }
                Section {
                    if resources.machines.isEmpty {
                        Text("No machines leased.").foregroundStyle(.secondary)
                    }
                    ForEach(resources.machines, id: \.id) { machine in
                        ResourceRow(title: title(of: machine.session) ?? machine.id,
                                    subtitle: [LeaseMarks.name(machine.platform), machine.config].compactMap { $0 }.joined(separator: " · "),
                                    platform: machine.platform, cpus: machine.cpus, cpuPercent: machine.cpuPercent,
                                    memoryLimit: machine.memoryLimitBytes, memoryUsed: machine.memoryBytes)
                    }
                } header: {
                    Text("Leased Machines")
                } footer: {
                    if let note = resources.machinesNote { Text(note) }
                }
                if let other = resources.machinesHost {
                    Section("The Machines' Computer") {
                        ResourceRow(title: other.name ?? "oss", cpus: other.cpus, cpuPercent: other.cpuPercent,
                                    memoryLimit: other.memoryBytes, memoryUsed: other.memoryUsedBytes)
                    }
                }
            } else {
                Text(asked ? "\(host.record.name) does not say what it is using." : "Asking \(host.record.name)…")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Resources")
        .task {
            while !Task.isCancelled {
                if let now = await host.resources() { resources = now }
                asked = true
                try? await Task.sleep(nanoseconds: Self.interval)
            }
        }
    }

    /// Said when the containers may use more memory together than the
    /// computer has: they take it as they need it, and keep it until they
    /// stop, so it is fine while they idle and not if they all build at
    /// once.
    static func overcommitted(_ resources: ServerResources) -> String? {
        guard let computer = resources.host else { return nil }
        let given = resources.containers.compactMap(\.memoryLimitBytes).reduce(0, +)
        guard given > computer.memoryBytes else { return nil }
        return "Together the containers may use \(ResourceRow.bytes(given)), more than this computer's \(ResourceRow.bytes(computer.memoryBytes)): "
            + "fine while they idle, not if they all build at once. A container keeps the memory it has used until it stops."
    }

    /// A session's name, as the list shows it.
    private func title(of session: String?) -> String? {
        guard let session, let info = host.sessions.first(where: { $0.id == session }) else { return nil }
        return info.title.isEmpty ? info.agent.title : info.title
    }
}
