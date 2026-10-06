// Adding a computer over SSH: the user and host its `sshd` knows, the
// Visor password, and this device's key, which goes in that user's
// authorized keys first.

import SwiftUI
import VisorClient

@MainActor
struct SSHConnectForm: View {
    let connect: (AgentServerRecord) -> Void
    @State private var address = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                TitledField(title: "SSH address") {
                    TextField("user@my-mac.local", text: $address)
                        .autocorrectionDisabled()
                        .keyboardTypeURL()
                        .accessibilityIdentifier("ssh-address")
                }
                TitledField(title: "Visor password") {
                    PasswordField("From the Visor menu bar app", text: $password)
                        .accessibilityIdentifier("ssh-password")
                }
            } header: {
                Text("Computer")
            } footer: {
                Text("A user and a computer whose SSH (Remote Login on a Mac) takes this device's key, as user@host or user@host:port. Visor Server runs there; it needs nothing open on the network but SSH.")
            }
            DeviceKeySection()
            Section {
                Button("Connect", action: submit)
                    .disabled(address.trimmed.isEmpty)
                    .accessibilityIdentifier("ssh-connect")
            }
        }
        .insetGroupedForm()
        .onSubmit(submit)
    }

    private func submit() {
        guard !address.trimmed.isEmpty else { return }
        connect(AgentServerRecord(name: address.trimmed, address: address.trimmed, secret: password, provider: SSHAgentServerProvider.name))
    }
}
