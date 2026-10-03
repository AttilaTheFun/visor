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
    /// The connection log as it was when this page opened.
    @State private var log = ""

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
            // What the client did about its connections, to send to
            // whoever is finding out why one was slow.
            Section {
                connectionLogShareLink(log)
                    .accessibilityIdentifier("share-log")
                Button("Copy Connection Log") { copyToPasteboard(log) }
                Button("Clear Connection Log", role: .destructive) {
                    ConnectionLog.shared.clear()
                    log = ConnectionLog.shared.text
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Every computer's sign-ins, drops and retries, and the app coming to the front and leaving it, with the time of each. Nothing of any conversation.")
            }
        }
        .insetGroupedForm()
        .onAppear {
            log = ConnectionLog.shared.text
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
