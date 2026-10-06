// A computer's settings (a Visor server's): its address and password
// (editable, reconnecting on save), its state in words, Reconnect, and
// Forget, shown in the detail column from the sidebar.

import SwiftUI
import VisorClient
import VisorProtocol
import VisorServices

@MainActor
struct ComputerSettingsForm: View {
    @ObservedObject var host: AgentServerConnection
    let forget: () -> Void
    @State private var name = ""
    @State private var address = ""
    @State private var password = ""
    /// The connection log as it was when this page opened.
    @State private var log = ""
    /// Whether the computer is reached over its own SSH.
    private var overSSH: Bool { SSHAddress(host.record.address) != nil }

    var body: some View {
        Form {
            Section {
                TitledField(title: "Name") { TextField("Name", text: $name) }
                TitledField(title: "Address") {
                    TextField("my-mac.tail1234.ts.net, https://… or user@host", text: $address)
                        .autocorrectionDisabled()
                        .keyboardTypeURL()
                }
                TitledField(title: "Password (if asked)") { PasswordField("Only if the computer asks", text: $password) }
            } header: {
                Text("Computer")
            } footer: {
                Text(host.state.wantsAuthentication
                     ? (overSSH
                        ? "The computer refused this device's key, or Visor Server refused the password. Put the key below in the user's authorized keys, check the password, and save."
                        : "This computer does not know this device as its owner's. Type the password its Visor menu bar app shows and save.")
                     : host.state.label + (host.state == .connected && !host.live
                        ? ". Followed by polling: this road carries no live channel, so updates arrive a little later, and terminal sessions cannot be drawn." : ""))
            }
            if overSSH, VisorHost.ssh != nil { DeviceKeySection() }
            if !host.record.roads.isEmpty || host.road != nil {
                Section {
                    if let road = host.road, road != host.record.address {
                        Text("Reached by \(road)").font(.footnote)
                    }
                    ForEach(host.record.roads, id: \.self) { road in
                        Text(road).font(.footnote.monospaced()).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                } header: {
                    Text("Other roads")
                } footer: {
                    Text("Addresses this computer and the others say it is reached at, tried in turn when the one above does not answer — and, last, through any other computer here that reaches it.")
                }
            }
            Section {
                Button("Save and reconnect", action: save)
                    .disabled(address.trimmed.isEmpty)
                Button("Reconnect") { host.connect() }
                Button("Forget this computer", role: .destructive, action: forget)
            }
            ConnectionCodeSection(host: host)
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
            record.rename(to: name)
            record.address = address.trimmed
            record.secret = password
        }
        host.connect()
    }
}
