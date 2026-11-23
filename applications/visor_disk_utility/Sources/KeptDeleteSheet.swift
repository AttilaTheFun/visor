// A kept volume's Delete…: everything on it goes, so its confirmation is
// typed ("delete Sessions-old-ci"), then the administrator's prompt.

import DiskVolumes
import SwiftUI

struct KeptDeleteSheet: View {
    let kept: KeptVolume
    let delete: (String) -> Void
    @State private var typed = ""
    @Environment(\.dismiss) private var dismiss

    /// What's lost with it.
    private var warning: String {
        switch kept.kind {
        case .rollback:
            "Everything on it is deleted, and it can't be put back: \(kept.role.volumeName) as it was before its conversion, "
                + "which unswap would bring back. Delete it once you're happy with the converted \(kept.role.volumeName)."
        case .failed:
            "Everything on it is deleted, and it can't be put back: the converted \(kept.role.volumeName) unswap took out, "
                + "with anything written on it between the swap and the unswap, which the \(kept.role.volumeName) in use doesn't have. "
                + "Mount it and copy out what you need first."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete \(kept.name)?").font(.title2)
            Text(kept.summary).foregroundStyle(.secondary)
            Text(warning + " Type \"\(kept.confirmation)\" to delete it:")
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
