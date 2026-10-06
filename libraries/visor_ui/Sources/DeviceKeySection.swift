import SwiftUI
import VisorServices

/// This device's SSH public key, to copy into a user's authorized keys.
@MainActor
struct DeviceKeySection: View {
    private var key: String { VisorHost.ssh?.publicKey() ?? "" }

    var body: some View {
        Section {
            Text(key)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
            Button("Copy Key") { copyToPasteboard(key) }
                .accessibilityIdentifier("copy-ssh-key")
        } header: {
            Text("This device's key")
        } footer: {
            Text("Add this line to ~/.ssh/authorized_keys for the user on the computer. It is made on this device and never leaves it.")
        }
    }
}
