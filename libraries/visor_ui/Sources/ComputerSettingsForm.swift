// A computer's settings (a Visor server's): its address and password
// (editable, reconnecting on save), its state in words, Reconnect, and
// Forget, shown in the detail column from the sidebar.

import SwiftUI
import VisorClient
import VisorProtocol
import VisorServices

@MainActor
struct ComputerSettingsForm: View {
    var host: AgentServerConnection
    let forget: () -> Void
    @State private var name = ""
    @State private var address = ""
    @State private var password = ""
    @State private var authentication = PasswordAuthenticator.name
    /// The connection log as it was when this page opened.
    @State private var log = ""
    /// Whether the computer is reached over its own SSH.
    private var overSSH: Bool { SSHAddress(host.record.address) != nil }

    /// The transport a path is: SSH, HTTPS or HTTP, through another
    /// computer when the path is a relay.
    static func transport(of path: String) -> String {
        if SSHAddress(path) != nil { return "SSH" }
        let scheme = path.lowercased().hasPrefix("https") ? "HTTPS" : "HTTP"
        return path.contains("/peer/") ? "\(scheme), through another computer" : scheme
    }

    /// How the connection signed in: by this device's key over SSH, else
    /// as the record's authenticator says.
    static func signIn(of path: String, record: AgentServerRecord) -> String {
        if SSHAddress(path) != nil { return "This device's SSH key" }
        return AgentServerAuthenticators.all.first { $0.id == record.authentication }?.title ?? "Password"
    }

    var body: some View {
        Form {
            // What the connection is, in plain rows, before anything editable.
            Section {
                LabeledContent("Status", value: host.state.label)
                if host.state == .connected, let path = host.path {
                    LabeledContent("Transport", value: Self.transport(of: path))
                    LabeledContent("Path", value: path)
                    LabeledContent("Sign-in", value: Self.signIn(of: path, record: host.record))
                    LabeledContent("Updates", value: host.live ? "Live" : "Polling")
                }
            } header: {
                Text("Connection")
            } footer: {
                if host.state == .connected, !host.live {
                    Text("Polling: this path carries no live channel, so updates arrive a little later, and terminal sessions cannot be drawn.")
                }
            }
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
                if host.state.wantsAuthentication {
                    Text(overSSH
                         ? "The computer refused this device's key, or Visor Server refused the password. Put the key below in the user's authorized keys, check the password, and save."
                         : "This computer does not know this device as its owner's. Type the password its Visor menu bar app shows and save.")
                }
            }
            if overSSH, VisorHost.ssh != nil { DeviceKeySection() }
            if !overSSH, VisorHost.ssh != nil, !host.sshPaths.isEmpty {
                Section {
                    Button("Use SSH") {
                        if host.useSSH() { address = host.record.address }
                    }
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
                // The account's computers come and go with its sign-in.
                if !host.record.fromAccount {
                    Button("Forget this computer", role: .destructive, action: forget)
                }
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
            load()
        }
        .onChange(of: host.record.address) { load() }
    }

    /// The fields from the record.
    private func load() {
        name = host.record.name
        address = host.record.address
        password = host.record.secret
        authentication = host.record.authentication
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
