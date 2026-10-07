import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import VisorProtocol
import VisorServer
import VisorServerApple

struct SettingsPane: View {
    var server: VisorServer
    @State private var draft = ""
    @State private var message: String?
    @State private var linkDraft = ""
    @State private var linkMessage: String?
    @State private var linking = false
    @State private var choosingKey = false
    @State private var keyPEM = ""
    @State private var publicAddress = ""
    @State private var tlsPath = ""
    @State private var tlsPassword = ""
    @State private var keyID = ""
    @State private var teamID = ""
    @State private var pushMessage: String?

    var body: some View {
        Form {
            Section {
                if let code = server.connectionCode {
                    HStack(alignment: .top, spacing: 16) {
                        if let image = QRCode.image(for: code.link) {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 168, height: 168)
                                .accessibilityLabel("QR code for connecting to this Mac")
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Scan with a phone's camera, or copy the code and paste it into Visor on another device (Computers → Add Computer).")
                                .font(.caption).foregroundColor(.secondary)
                            Text(code.encoded)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(4)
                                .truncationMode(.middle)
                            Button("Copy Code") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code.encoded, forType: .string)
                            }
                        }
                    }
                    Text("The code holds this Mac's address and password: share it only with your own devices.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text(server.password.isEmpty ? "Set a password below to get a connection code." : "Open the server to the network, or set an address, below, to get a connection code.")
                        .font(.caption).foregroundColor(.secondary)
                }
            } header: {
                Text("Connect a device")
            }
            Section {
                TextField("Required", text: $draft)
                HStack {
                    Button("Save") { save() }
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || draft == server.password)
                        .keyboardShortcut(.defaultAction)
                    Button("Generate") { draft = VisorServer.generatePassword() }
                }
                Text(server.password.isEmpty
                     ? "Visor does not serve until a password is set. Every client and every tool on this Mac signs in with it; the connection code carries it."
                     : "Clients that are already connected stay connected; new logins use the new password.")
                    .font(.caption).foregroundColor(.secondary)
                if let message { Text(message).font(.caption).foregroundColor(.red) }
                Picker("Clients show", selection: Binding(get: { server.settings.authentication },
                                                           set: { server.settings.authentication = $0 })) {
                    Text("The password").tag("password")
                    Text("Nothing").tag("none")
                }
                Text(server.settings.asksNothing
                     ? "Anyone who reaches the server is let in: keep it to paths of your own — this Mac, a VPN of yours, SSH, or a front that signs users in before it reaches Visor."
                     : "A client signs in with the password (or a token it was given for it); SSH clients at the socket file need neither.")
                    .font(.caption).foregroundColor(.secondary)
            } header: {
                Text("Password")
            }
            Section {
                let addresses = NetworkAddresses.all().map { NetworkAddress(address: $0.address, interface: $0.name) }
                pathRow("http://127.0.0.1:\(String(server.port))")
                Text("This Mac: always on, for its own Visor and its agents' tools.").font(.caption).foregroundColor(.secondary)
                Toggle("LAN", isOn: Binding(get: { server.settings.lan }, set: { server.settings.lan = $0 }))
                if server.settings.lan {
                    ForEach(addresses.filter { $0.kind == .lan }, id: \.address) { entry in
                        pathRow("\(server.servesTLS ? "https" : "http")://\(entry.address):\(String(server.port))", note: entry.interface)
                    }
                }
                Toggle("VPN", isOn: Binding(get: { server.settings.vpn }, set: { server.settings.vpn = $0 }))
                if server.settings.vpn {
                    ForEach(addresses.filter { $0.kind == .vpn }, id: \.address) { entry in
                        pathRow("\(server.servesTLS ? "https" : "http")://\(entry.address):\(String(server.port))", note: entry.interface)
                    }
                }
                Toggle("SSH", isOn: Binding(get: { server.settings.sshEnabled }, set: { server.settings.sshEnabled = $0 }))
                if server.settings.sshEnabled {
                    ForEach(server.sshPaths, id: \.self) { path in pathRow(path) }
                    Text("Through this Mac's Remote Login, as you: no password asked (the socket file ~/.visor/server.sock).")
                        .font(.caption).foregroundColor(.secondary)
                }
                Toggle("Reverse proxy", isOn: Binding(get: { server.settings.proxyEnabled }, set: { server.settings.proxyEnabled = $0 }))
                if server.settings.proxyEnabled {
                    TextField("https://proxy.example.com/visor", text: $publicAddress)
                        .onSubmit { server.settings.publicAddress = publicAddress }
                    if !server.settings.publicAddress.isEmpty { pathRow(server.settings.publicAddress) }
                    Text("A proxy, a tunnel or a name with certificates in front of this Mac, scheme and all; clients are told it first, and it is what the connection code carries. One that passes no WebSockets still works: clients poll. Press Return to apply.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Text("Each path is a way in; what a client must show is the sign-in above. The LAN's and a VPN's addresses change with the network; this list is as it is now.")
                    .font(.caption).foregroundColor(.secondary)
                TextField("TLS identity, a .p12 file (empty: plain, or TLS is the front's)", text: $tlsPath)
                    .onSubmit { server.settings.tlsIdentityPath = tlsPath }
                SecureField("The .p12 file's password", text: $tlsPassword)
                    .onSubmit { server.settings.tlsIdentityPath = tlsPath; server.setTLSPassword(tlsPassword) }
                Text(server.servesTLS ? "Serving TLS with the identity above." : "Serving plain TCP: TLS, if any, is the front's. Press Return in a field to apply it.")
                    .font(.caption).foregroundColor(.secondary)
                if let error = server.lastError { Text(error).font(.caption).foregroundColor(.red) }
            } header: {
                Text("Network paths")
            }
            Section {
                ForEach(server.peers, id: \.self) { peer in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(peer.name)
                            Text(peer.addresses.joined(separator: ", ")).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Forget") { server.forget(peer: peer.id.isEmpty ? (peer.addresses.first ?? "") : peer.id) }
                    }
                }
                HStack {
                    TextField("Another computer's connection code", text: $linkDraft)
                    Button("Add") { link() }
                        .disabled(linking || linkDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("The computers on the network: the agents here reach the sessions on each, and each reaches the ones here; a client of any of them learns of the rest, and is carried to one it cannot reach itself. A client that holds two computers introduces them; or paste a code here, once.")
                    .font(.caption).foregroundColor(.secondary)
                if let linkMessage { Text(linkMessage).font(.caption).foregroundColor(.red) }
            } header: {
                Text("Computers on the network")
            }
            Section {
                let current = server.apnsKey
                Text(current.configured
                     ? "Key \(current.keyID) is set; \(server.pushDeviceCount) device\(server.pushDeviceCount == 1 ? "" : "s") asked for notifications."
                     : "Not set up: phones hear of finished turns only while Visor is open.")
                    .font(.caption).foregroundColor(.secondary)
                HStack {
                    Button(keyPEM.isEmpty ? "Choose APNs Key (.p8)…" : "Key chosen") { choosingKey = true }
                    Spacer()
                    Button("Send Test") { pushMessage = server.sendTestPush() ?? "Sent." }
                        .disabled(!current.configured)
                }
                TextField("Key ID", text: $keyID)
                TextField("Team ID", text: $teamID)
                Button("Save Key") {
                    pushMessage = server.setAPNsKey(pem: keyPEM, keyID: keyID.trimmingCharacters(in: .whitespaces),
                                                    teamID: teamID.trimmingCharacters(in: .whitespaces)) ?? "Saved."
                    if pushMessage == "Saved." { keyPEM = "" }
                }
                .disabled(keyPEM.isEmpty || keyID.isEmpty || teamID.isEmpty)
                Text("An APNs key from your Apple developer account (Keys → Apple Push Notifications service). It stays in this Mac's keychain. A push says only the session's name and what happened: \"Isomer: Goal achieved in 1h45m\".")
                    .font(.caption).foregroundColor(.secondary)
                if let pushMessage { Text(pushMessage).font(.caption) }
            } header: {
                Text("Push Notifications")
            }
            .fileImporter(isPresented: $choosingKey, allowedContentTypes: [.item]) { result in
                guard let url = try? result.get() else { return }
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                keyPEM = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                // Apple names the file AuthKey_<key id>.p8.
                let name = url.deletingPathExtension().lastPathComponent
                if name.hasPrefix("AuthKey_") { keyID = String(name.dropFirst(8)) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 760)
        .onAppear {
            publicAddress = server.settings.publicAddress
            tlsPath = server.settings.tlsIdentityPath
            keyID = server.apnsKey.keyID
            teamID = server.apnsKey.teamID
            draft = server.password.isEmpty ? VisorServer.generatePassword() : server.password
        }
    }

    /// One path's address, selectable, with a Copy button.
    private func pathRow(_ path: String, note: String = "") -> some View {
        HStack {
            Text(path).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            if !note.isEmpty { Text(note).font(.caption).foregroundColor(.secondary) }
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
    }

    private func link() {
        linking = true
        linkMessage = nil
        Task {
            linkMessage = await server.link(linkDraft)
            // Kept here, even if the other did not link back: the code is done with.
            if let code = ConnectionCode(parsing: linkDraft), server.peers.contains(where: { $0.isSame(as: code.peer) }) { linkDraft = "" }
            linking = false
        }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { message = "A password is required."; return }
        server.password = trimmed
        draft = trimmed
        message = nil
    }
}
