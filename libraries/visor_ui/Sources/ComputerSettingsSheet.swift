// A computer's settings: its address and password (editable, reconnecting
// on save), its state in words, Reconnect, and Forget. The form is one
// view; the sidebar shows it in the detail, or in a sheet.

import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct ComputerSettingsForm: View {
    @ObservedObject var host: HostConnection
    let forget: () -> Void
    /// Called after a save or a forget, for a container that then closes.
    var done: () -> Void = {}
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
                Button("Forget this computer", role: .destructive) {
                    done()
                    forget()
                }
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
        done()
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

/// The same settings as a sheet, from the Computers list.
@MainActor
struct ComputerSettingsSheet: View {
    @ObservedObject var host: HostConnection
    let forget: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ComputerSettingsForm(host: host, forget: forget, done: { dismiss() })
                .navigationTitle(host.config.name.isEmpty ? "Computer" : host.config.name)
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .presentationDetentsMediumLarge()
    }
}
