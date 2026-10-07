import SwiftUI
import VisorProtocol
import VisorServices

/// This device's SSH public key: to copy into a user's authorized keys,
/// or as a QR code for a device that already holds the computers to
/// scan, which has them authorize it.
@MainActor
struct DeviceKeySection: View {
    @State private var shown = false
    private var key: String { VisorHost.ssh?.publicKey() ?? "" }

    var body: some View {
        Section {
            Text(key)
                .font(.footnote.monospaced())
                .selectableText()
                .lineLimit(3)
                .truncationMode(.middle)
            Button("Copy Key") { copyToPasteboard(key) }
                .accessibilityIdentifier("copy-ssh-key")
            Button(shown ? "Hide QR Code" : "Show Key as QR Code") { shown.toggle() }
                .accessibilityIdentifier("show-key-qr")
            if shown, let qr = QRCode(SSHKeyLink(key: key).link) {
                QRCodeShape(code: qr)
                    .fill(Color.black)
                    .background(Color.white)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 280)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .accessibilityLabel("This device's SSH key")
            }
        } header: {
            Text("This device's key")
        } footer: {
            Text("Made on this device; the private half never leaves it. Add the line to ~/.ssh/authorized_keys for the user on the computer — or scan the QR code with a phone or Mac that already holds your computers, and they authorize it; this device then connects over SSH straight away.")
        }
    }
}
