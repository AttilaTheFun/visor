// A Mac's settings (the Tailscale provider's): its address and password
// (editable, reconnecting on save), its state in words, Reconnect, and
// Forget, shown in the detail column from the sidebar.

import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct ComputerSettingsForm: View {
    @ObservedObject var host: AgentServerConnection
    let forget: () -> Void
    @State private var name = ""
    @State private var address = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                TitledField(title: "Name") { TextField("Name", text: $name) }
                TitledField(title: "Tailscale name") {
                    TextField("my-mac.tail1234.ts.net", text: $address)
                        .autocorrectionDisabled()
                        .keyboardTypeURL()
                }
                TitledField(title: "Password (if asked)") { PasswordField("Only if the computer asks", text: $password) }
            } header: {
                Text("Computer")
            } footer: {
                Text(host.state.wantsAuthentication
                     ? "This computer does not know this device as its owner's. Type the password its Visor menu bar app shows and save."
                     : host.state.label)
            }
            Section {
                Button("Save and reconnect", action: save)
                    .disabled(address.trimmed.isEmpty)
                Button("Reconnect") { host.connect() }
                Button("Forget this computer", role: .destructive, action: forget)
            }
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
