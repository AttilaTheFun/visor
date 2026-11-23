// A kept volume's Delete…: everything on it goes, so its confirmation is
// typed ("delete Sessions-old-ci"), then the administrator's prompt.

import DiskVolumes
import SwiftUI

struct KeptDeleteSheet: View {
    let kept: KeptVolume
    let delete: (String) -> Void
    @State private var typed = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete \(kept.name)?").font(.title2)
            Text(kept.summary).foregroundStyle(.secondary)
            Text("Everything on it is deleted, and it can't be put back: \(kept.role.volumeName) can't be rolled back to it after. "
                 + "Type \"\(kept.confirmation)\" to delete it:")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            TextField(kept.confirmation, text: $typed)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Delete", role: .destructive) {
                    delete(typed)
                    dismiss()
                }
                .disabled(!kept.matches(typed))
            }
        }
        .padding(20)
        .frame(minWidth: 480)
    }
}
