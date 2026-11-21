// The window: Sessions, Sources, then Visor.

import DiskVolumes
import SwiftUI

/// The three volumes, a refresh, and where Visor reads them from.
struct VolumesView: View {
    @Bindable var model: VolumesModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Visor keeps everything of its own on three volumes of this Mac's disk: its sessions on Sessions, their checkouts on Sources, and its data, logs and container on Visor.")
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
