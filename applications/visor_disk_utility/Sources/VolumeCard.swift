// One volume: whether it's there, what it is, its space, and what can be
// done. Sessions has no erase, ever.

import DiskVolumes
import SwiftUI

struct VolumeCard: View {
    @Bindable var model: VolumesModel
    let role: VolumeRole
    @State private var confirmingErase = false

    private var state: VolumeState? { model.states[role] }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(role.purpose).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    row("Status", status)
                    row("Path", state?.path ?? role.mountPoint)
                    row("Format", format)
                    if let volume = state?.volume {
                        row("Used", ByteSize.describe(volume.used))
                    }
                    row("Free", state?.available.map(ByteSize.describe) ?? "—")
                    sizeRow("Reserve", text: binding(\.reserve), help: "Space set aside for it alone. Empty for none.")
                    sizeRow("Quota", text: binding(\.quota), help: "The most it may hold. Empty for no limit.")
                }
                if state?.exists == true {
                    Text(role.isErasable
                         ? "diskutil can't change a volume's reserve or quota once it's made: Erase Containers… remakes it with these."
                         : "diskutil can't change a volume's reserve or quota once it's made, and Sessions is never erased.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(notes, id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    if role.isErasable {
                        Button("Erase Containers…", role: .destructive) { confirmingErase = true }
                            .disabled(model.isBusy || state?.exists != true)
                    }
                    Button("Create") { Task { await model.create(role) } }
                        .disabled(model.isBusy || !canCreate)
                }
            }
            .padding(6)
        } label: {
            Text(role.volumeName).font(.headline)
        }
        .confirmationDialog("Erase Containers?", isPresented: $confirmingErase) {
            Button("Erase Containers", role: .destructive) { Task { await model.eraseContainers() } }
        } message: {
            Text("Everything on Containers is deleted: the container's image, root filesystem, caches and logs. "
                 + "The volume is made again, case-sensitive, with the reserve and quota above. Sessions isn't touched.")
        }
    }

    private var canCreate: Bool {
        if case .create = state?.plan { return true }
        return false
    }

    /// Reserve and quota are typed for a volume to be made, and for
    /// Containers' erase; an existing Sessions' are shown as they are.
    private var sizesEditable: Bool { canCreate || (role.isErasable && state?.exists == true) }

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
        switch state.isCaseSensitive {
        case true?: return "\(state.format) (case-sensitive)"
        case false?: return "\(state.format) (case-insensitive)"
        case nil: return state.format
        }
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
