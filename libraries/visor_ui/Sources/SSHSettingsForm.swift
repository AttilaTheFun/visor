// A computer reached over SSH: its address and Visor password (editable,
// reconnecting on save), its state in words, this device's key, Reconnect
// and Forget.

import SwiftUI
import VisorClient

@MainActor
struct SSHSettingsForm: View {
    @ObservedObject var host: AgentServerConnection
    let forget: () -> Void
    @State private var name = ""
    @State private var address = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                TitledField(title: "Name") { TextField("Name", text: $name) }
                TitledField(title: "SSH address") {
                    TextField("user@my-mac.local", text: $address)
                        .autocorrectionDisabled()
                        .keyboardTypeURL()
                }
                TitledField(title: "Visor password") { PasswordField("From the Visor menu bar app", text: $password) }
            } header: {
                Text("Computer over SSH")
            } footer: {
                Text(host.state.wantsAuthentication
                     ? "The computer refused this device's key, or Visor Server refused the password. Put the key below in the user's authorized keys, check the password, and save."
                     : host.state.label)
            }
            Section {
                Button("Save and reconnect", action: save)
                    .disabled(address.trimmed.isEmpty)
                Button("Reconnect") { host.connect() }
                Button("Forget this computer", role: .destructive, action: forget)
            }
            DeviceKeySection()
            ConnectionCodeSection(host: host)
        }
        .insetGroupedForm()
        .onAppear {
            name = host.record.name
            address = host.record.address
            password = host.record.secret
        }
    }

    private func save() {
        host.disconnect()
        host.update { record in
            record.name = name.trimmed
            record.address = address.trimmed
            record.secret = password
        }
        host.connect()
    }
}
