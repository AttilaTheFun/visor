// Sessions and Sources converted to case-sensitive APFS
// (docs/volume-conversion.md): where each stands, Stage and Swap In (one
// administrator prompt each, for every volume they apply to), what the
// swap left, and the volumes kept for rollback, each with its Delete….

import DiskVolumes
import SwiftUI

struct ConversionBox: View {
    @Bindable var model: VolumesModel
    @State private var deleting: KeptVolume?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("A case-insensitive Sessions or Sources is converted by a copy: Stage makes a case-sensitive one beside it "
                     + "(<Name>-new), NCH copies onto it and checks every file over SSH while Visor is stopped, then Swap In "
                     + "puts the copy in its place and keeps the old one, unmounted, for rollback.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(VolumeRole.convertible, id: \.self) { role in
                    Label(model.conversions[role]?.summary ?? "Looking…", systemImage: icon(role))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                ForEach(model.conversionResult, id: \.self) { line in
                    Label(line, systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                ForEach(model.kept) { kept in
                    HStack {
                        Text(kept.summary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Spacer()
                        Button("Delete…", role: .destructive) { deleting = kept }
                            .disabled(model.isBusy)
                    }
                }
                HStack {
                    Spacer()
                    Button(title("Stage", model.stageable)) { Task { await model.stage() } }
                        .disabled(model.isBusy || model.stageable.isEmpty)
                        .help("Makes <Name>-new, case-sensitive, with the volume's own quota and reserve, and gives it to you: the administrator's prompt.")
                    Button(title("Swap In", model.swappable)) { Task { await model.swapIn() } }
                        .disabled(model.isBusy || model.swappable.isEmpty)
                        .help("Visor's server must be stopped and nothing using the volumes. The old volume is renamed <Name>-old-ci and "
                              + "unmounted, the verified copy renamed and mounted in its place: the administrator's prompt.")
                }
            }
            .padding(6)
        } label: {
            Text("Convert to Case-Sensitive").font(.headline)
        }
        .sheet(item: $deleting) { kept in
            KeptDeleteSheet(kept: kept) { typed in Task { await model.deleteKept(kept, typed: typed) } }
        }
    }

    private func title(_ action: String, _ roles: [VolumeRole]) -> String {
        roles.isEmpty ? action : "\(action) " + roles.map(\.volumeName).joined(separator: " and ")
    }

    private func icon(_ role: VolumeRole) -> String {
        switch model.conversions[role]?.phase {
        case .converted?: "checkmark.circle"
        case .ready?: "circle"
        case .staged(.verified)?: "checkmark.seal"
        case .staged?: "clock"
        case .unavailable?, nil: "minus.circle"
        }
    }
}
