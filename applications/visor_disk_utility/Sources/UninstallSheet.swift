// Uninstall…: the dry run first (everything Visor left on this Mac, what's
// only listed, and what's for a person to undo by hand), the volumes only
// when asked and their names typed, then what was done. Nothing runs until
// Uninstall is pressed.

import SwiftUI
import VisorUninstall

struct UninstallSheet: View {
    @Bindable var model: UninstallModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Uninstall Visor").font(.title2)
            Text("Everything Visor left on this Mac outside its volumes goes, and the apps last. Nothing is done until you press Uninstall.")
                .foregroundStyle(.secondary)
            ScrollView {
                Text(model.done.isEmpty ? (model.plan?.dryRun ?? "Looking…") : model.done.joined(separator: "\n"))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 320)
            if model.done.isEmpty {
                Toggle("Also delete the Sessions, Sources and Visor volumes, with everything on them", isOn: $model.deleteVolumes)
                    .onChange(of: model.deleteVolumes) { Task { await model.look() } }
                if let phrase = model.phrase {
                    Text("Type \"\(phrase)\" to delete them:").foregroundStyle(.red)
                    TextField(phrase, text: $model.typed)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
            }
            if let failure = model.failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Spacer()
                if model.done.isEmpty {
                    Button("Cancel", role: .cancel) { dismiss() }
                    Button("Uninstall", role: .destructive) { Task { await model.run() } }
                        .disabled(!model.canRun)
                } else {
                    Button("Quit") { model.finish() }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 640)
        .task { await model.look() }
    }
}
