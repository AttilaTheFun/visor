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
    @State private var authentication = PasswordAuthenticator.name
    /// The connection log as it was when this page opened.
    @State private var log = ""
    /// Whether the computer is reached over its own SSH.
    private var overSSH: Bool { SSHAddress(host.record.address) != nil }

    /// The state, and for a connected computer the path it is connected
    /// by: "Connected over SSH (ssh://logan@10.0.0.2), no password" or
    /// "Connected over HTTP (http://10.0.0.2:7433), with the password".
    private var connectedBy: String {
        guard host.state == .connected, let path = host.path else { return host.state.label }
        if SSHAddress(path) != nil { return "Connected over SSH (\(path)), signed in by this device's key." }
        let relayed = path.contains("/peer/") ? ", through another computer" : ""
        let how = host.record.authentication == NoAuthenticator.name ? "no sign-in asked" : "with the password"
        return "Connected over \(path.lowercased().hasPrefix("https") ? "HTTPS" : "HTTP") (\(path))\(relayed), \(how)."
    }

    var body: some View {
        Form {
            Section {
                TitledField(title: "Name") { TextField("Name", text: $name) }
                TitledField(title: "Address") {
                    TextField("my-mac.tail1234.ts.net, https://… or user@host", text: $address)
                        .autocorrectionDisabled()
                        .keyboardTypeURL()
                }
                AuthenticationRows(address: address.trimmed, authentication: $authentication, secret: $password)
            } header: {
                Text("Computer")
            } footer: {
                Text(host.state.wantsAuthentication
                     ? (overSSH
                        ? "The computer refused this device's key, or Visor Server refused the password. Put the key below in the user's authorized keys, check the password, and save."
                        : "This computer does not know this device as its owner's. Type the password its Visor menu bar app shows and save.")
                     : connectedBy + (host.state == .connected && !host.live
                        ? " Followed by polling: this path carries no live channel, so updates arrive a little later, and terminal sessions cannot be drawn." : ""))
            }
            if overSSH, VisorHost.ssh != nil { DeviceKeySection() }
            if !overSSH, VisorHost.ssh != nil, !host.sshPaths.isEmpty {
                Section {
                    Button("Use SSH") { host.useSSH() }
                        .accessibilityIdentifier("use-ssh")
                } footer: {
                    Text("Makes the computer's own SSH the way in: this device's key is handed to the computer over the connection it has now, and the connection made again over SSH, with no password asked from then on.")
                }
            }
            if !host.record.paths.isEmpty || host.path != nil {
                Section {
                    if let path = host.path, path != host.record.address {
                        Text("Reached by \(path)").font(.footnote)
                    }
                    ForEach(host.record.paths, id: \.self) { path in
                        Text(path).font(.footnote.monospaced()).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                } header: {
                    Text("Network paths")
                } footer: {
                    Text("The other ways this computer is reached, as it and the others say: tried in turn when the address above does not answer — and, last, through any other computer here that reaches it.")
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
            authentication = host.record.authentication
        }
    }

    private func save() {
        host.disconnect()
        host.update { record in
            record.rename(to: name)
            record.address = address.trimmed
            record.secret = password
            record.authentication = authentication
        }
        host.connect()
    }
}
