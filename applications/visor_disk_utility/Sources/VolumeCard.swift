// One volume: whether it's there, what it is, its space, and what can be
// done: Create, Fix, and Visor's exclusions. No volume is ever erased here.

import DiskVolumes
import SwiftUI

struct VolumeCard: View {
    @Bindable var model: VolumesModel
    let role: VolumeRole

    private var state: VolumeState? { model.states[role] }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(role.purpose).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    row("Status", status)
                    row("Path", state?.path ?? role.mountPoint)
                    row("Format", format)
                    if let used = state?.usedDescription {
                        row("Used", used)
                    }
                    row("Free", state?.available.map(ByteSize.describe) ?? "—")
                    if role == .visor, let exclusions = model.visorExclusions {
                        row("Backups", exclusions.summary)
                    }
                    sizeRow("Reserve", text: binding(\.reserve), help: "Space set aside for it alone. Empty for none.")
                    sizeRow("Quota", text: binding(\.quota), help: "The most it may hold. Empty for no limit.")
                }
                if state?.exists == true {
                    Text("diskutil can't change a volume's reserve or quota once it's made, and Visor Disk Utility never erases one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let owner = model.foreignOwner(role) {
                    HStack {
                        Label("Owned by \(owner): Visor can't write here.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Fix") { Task { await model.fixOwner(role) } }
                            .disabled(model.isBusy)
                            .help("Gives \(role.mountPoint) to you (chown, chmod 775), with the administrator's prompt.")
                    }
                }
                ForEach(notes, id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    if role == .visor {
                        // Left out of Time Machine and Spotlight again, where it isn't.
                        if let exclusions = model.visorExclusions, !exclusions.isComplete {
                            Button("Leave Out of Backups…") { Task { await model.excludeVisor() } }
                                .disabled(model.isBusy)
                                .help("Spotlight is turned off on it; Time Machine's settings open, to add it under Options… › +.")
                        }
                    }
                    Button("Create") { Task { await model.create(role) } }
                        .disabled(model.isBusy || !canCreate)
                }
            }
            .padding(6)
        } label: {
            Text(role.volumeName).font(.headline)
        }
    }

    private var canCreate: Bool {
        if case .create = state?.plan { return true }
        return false
    }

    /// Reserve and quota are typed for a volume to be made; an existing
    /// one's are shown as they are.
    private var sizesEditable: Bool { canCreate }

    private var status: String {
        switch state?.plan {
        case nil: "Looking…"
        case .adopt?: "Exists (\(state?.volume?.device ?? "")): adopted as it is"
        case .create?: "Not created yet"
        case .blocked?: "Can't be used as it is"
        }
    }

    private var format: String {
        guard let state else { return "—" }
        guard state.exists else { return "\(state.format) (when created)" }
        // "Case-sensitive APFS" says so; plain "APFS" is case-insensitive.
        return state.isCaseSensitive == false ? "\(state.format) (case-insensitive)" : state.format
    }

    private var notes: [String] {
        guard let state else { return [] }
        if case let .blocked(why) = state.plan { return [why] + state.notes }
        return state.notes
    }

    private func binding(_ path: ReferenceWritableKeyPath<VolumesModel, [VolumeRole: String]>) -> Binding<String> {
        Binding(get: { model[keyPath: path][role] ?? "" }, set: { model[keyPath: path][role] = $0 })
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func sizeRow(_ title: String, text: Binding<String>, help: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField("none", text: text)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .disabled(!sizesEditable || model.isBusy)
                Text("GB").foregroundStyle(.secondary)
            }
            .help(help)
        }
    }
}
