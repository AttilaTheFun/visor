// A computer's settings: its address and password (editable, reconnecting
// on save), its state in words, Reconnect, and Forget, shown in the detail
// column from the sidebar.

import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct ComputerSettingsForm: View {
    @ObservedObject var host: HostConnection
    let forget: () -> Void
    @State private var name = ""
    @State private var address = ""
    @State private var password = ""

    private var backend: any Backend { Backends.backend(for: host.config.backend) ?? TailscaleBackend() }

    var body: some View {
        Form {
            Section {
                TitledField(title: "Name") { TextField("Name", text: $name) }
                TitledField(title: backend.hostFieldTitle) {
                    TextField(backend.hostPlaceholder, text: $address)
                        .autocorrectionDisabled()
                        .keyboardTypeURL()
                }
                TitledField(title: backend.passwordFieldTitle) { PasswordField("Only if the computer asks", text: $password) }
            } header: {
                Text("Computer")
            } footer: {
                Text(host.state.wantsPassword
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
            name = host.config.name
            address = host.config.host
            password = host.config.password
        }
    }

    private func save() {
        host.disconnect()
        host.update { config in
            config.name = name.trimmed
            config.host = address.trimmed
            config.password = password
        }
        host.connect()
    }
}

/// The settings in the detail column, for a computer selected in the sidebar.
@MainActor
struct ComputerSettingsView: View {
    @ObservedObject var host: HostConnection
    let forget: () -> Void

    var body: some View {
        ComputerSettingsForm(host: host, forget: forget)
            .navigationTitle(host.config.name.isEmpty ? "Computer" : host.config.name)
    }
}
