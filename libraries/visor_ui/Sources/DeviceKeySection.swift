import SwiftUI
import VisorClient
import VisorPasteboard
import VisorProtocol
import VisorServices

/// This device's SSH public key: to copy into a user's authorized keys,
/// or as a QR code for a device that already holds the computers to
/// scan, which has them authorize it. With a computer (its settings),
/// "Forget this device" takes the key out of that computer's authorized
/// keys, where Visor put it (its line tagged `visor:<device>`).
@MainActor
struct DeviceKeySection: View {
    /// The computer whose settings these are; nil while adding one.
    var host: AgentServerConnection?
    @State private var shown = false
    @State private var forgetting = false
    @State private var said: String?
    private var key: String { VisorHost.ssh?.publicKey() ?? "" }

    var body: some View {
        Section {
            Text(key)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
            Button("Copy Key") { Pasteboard.string = key }
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
            if let host, host.state == .connected {
                Button("Forget This Device", role: .destructive) { forget(on: host) }
                    .disabled(forgetting || key.isEmpty)
                    .accessibilityIdentifier("forget-device")
                if let said { Text(said).font(.footnote).foregroundColor(.secondary) }
            }
        } header: {
            Text("This device's key")
        } footer: {
            Text("Made on this device; the private half never leaves it. Add the line to ~/.ssh/authorized_keys for the user on the computer — or scan the QR code with a phone or Mac that already holds your computers, and they authorize it; this device then connects over SSH straight away."
                 + (host == nil ? "" : " Forget This Device takes it out of this computer's authorized keys where Visor put it; this device then comes in by its password."))
        }
    }

    /// The key taken out of the computer's authorized keys.
    private func forget(on host: AgentServerConnection) {
        forgetting = true
        Task {
            do {
                try await host.forgetDeviceKey()
                said = "This device's key is no longer authorized on this computer."
            } catch {
                said = "The key wasn't forgotten: \(error)"
            }
            forgetting = false
        }
    }
}
