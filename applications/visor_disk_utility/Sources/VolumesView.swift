// The window: Sessions, then Containers.

import DiskVolumes
import SwiftUI

/// Both volumes, a refresh, and where Visor reads them from.
struct VolumesView: View {
    @Bindable var model: VolumesModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Visor's container runner keeps its sessions on the Sessions volume and its container on the Containers volume, both on this Mac's disk.")
                    .foregroundStyle(.secondary)
                ForEach(VolumeRole.allCases, id: \.self) { role in
                    VolumeCard(model: model, role: role)
                }
                Text(model.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.isBusy)
            }
            if model.isBusy {
                ToolbarItem { ProgressView().controlSize(.small) }
            }
        }
        .alert("Visor Disk Utility", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.failure ?? "")
        }
    }
}
