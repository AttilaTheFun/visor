import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Network
import SwiftUI
import Synchronization
import VisorProtocol
import VisorServer
import VisorServerApple

struct SettingsPane: View {
    var server: VisorServer
    @State private var draft = ""
    @State private var message: String?
    /// Whether this Mac's sshd answers on port 22 (Remote Login), as last
    /// checked; nil before the check.
    @State private var remoteLogin: Bool?
    @State private var choosingKey = false
    @State private var keyPEM = ""
    @State private var publicAddress = ""
    @State private var tlsPath = ""
    @State private var tlsPassword = ""
    /// The field being edited, so leaving it applies what was typed: an
    /// address that only Return applied was easy to leave unapplied.
    @FocusState private var editing: EditedField?
    enum EditedField: Hashable { case publicAddress, tlsPath, tlsPassword, containerHost, containerImage, containerCallback }
    @State private var containerHost = ""
    @State private var containerImage = ""
    @State private var containerCallback = ""
    @State private var keyID = ""
    @State private var teamID = ""
    @State private var pushMessage: String?

    var body: some View {
        Form {
            Section {
                if let codes = server.connectionCodes {
                    HStack(alignment: .top, spacing: 16) {
                        if let image = QRCode.image(for: codes.link) {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 168, height: 168)
                                .accessibilityLabel("QR code for connecting to this Mac")
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Scan with a phone's camera, or copy the code and paste it into Visor on another device (Computers → Add Computer).")
                                .font(.caption).foregroundColor(.secondary)
                            Text(codes.qr)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(4)
                                .truncationMode(.middle)
                            ForEach(ConnectionPath.allCases, id: \.self) { kind in
                                if let code = codes.code(for: kind) {
                                    Button("Copy \(kind.title) Code") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(code, forType: .string)
                                    }
                                }
                            }
                        }
                    }
                    Text("The code holds this Mac's address and password: share it only with your own devices. Each copy leads with that kind of path (the others follow it); a device that has this Mac shows the same codes in its settings, to hand it on.")
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
                    if remoteLogin == false {
                        Text("Remote Login is off on this Mac, so nothing reaches these yet: turn it on in System Settings → General → Sharing.")
                            .font(.caption).foregroundColor(.red)
                    } else {
                        Text("Through this Mac's Remote Login, as you: no password asked (the socket file ~/.visor/server.sock).")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Toggle("Reverse proxy", isOn: Binding(get: { server.settings.proxyEnabled }, set: { server.settings.proxyEnabled = $0 }))
                if server.settings.proxyEnabled {
                    TextField("https://proxy.example.com/visor", text: $publicAddress)
                        .focused($editing, equals: .publicAddress)
                        .onSubmit { apply(.publicAddress) }
                    if !server.settings.publicAddress.isEmpty { pathRow(server.settings.publicAddress) }
                    Text("A proxy, a tunnel or a name with certificates in front of this Mac, scheme and all; clients are told it first, and it is what the connection code carries. One that passes no WebSockets still works: clients poll. Applied on Return, or on leaving the field.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Text("Each path is a way in; what a client must show is the sign-in above. The LAN's and a VPN's addresses change with the network; this list is as it is now.")
                    .font(.caption).foregroundColor(.secondary)
                TextField("TLS identity, a .p12 file (empty: plain, or TLS is the front's)", text: $tlsPath)
                    .focused($editing, equals: .tlsPath)
                    .onSubmit { apply(.tlsPath) }
                SecureField("The .p12 file's password", text: $tlsPassword)
                    .focused($editing, equals: .tlsPassword)
                    .onSubmit { apply(.tlsPassword) }
                Text(server.servesTLS ? "Serving TLS with the identity above." : "Serving plain TCP: TLS, if any, is the front's. A field applies on Return, or on leaving it.")
                    .font(.caption).foregroundColor(.secondary)
                if let error = server.lastError { Text(error).font(.caption).foregroundColor(.red) }
            } header: {
                Text("Network paths")
            }
            Section {
                // Set in the environment, the environment's word stands.
                let given = VisorServer.detachingSet()
                Toggle("Run agents apart from the server", isOn: Binding(get: { given ?? server.settings.detachAgents },
                                                                          set: { server.settings.detachAgents = $0 }))
                    .disabled(given != nil)
                Text(given != nil
                     ? "Set by VISOR_DETACH_AGENT_HOST in Visor Server's environment."
                     : "Each session's agent runs under a host of its own, so restarting or updating Visor Server leaves it working, and one that runs away cannot take the server down. Off, agents are the server's own children: a restart stops them. Applies to agents started from now on.")
                    .font(.caption).foregroundColor(.secondary)
            } header: {
                Text("Agents")
            }
            Section {
                TextField("Container host (empty: \(VisorServer.containerHostName) on the PATH)", text: $containerHost)
                    .focused($editing, equals: .containerHost)
                    .onSubmit { apply(.containerHost) }
                TextField("Image (empty: \(server.defaultContainerImage))", text: $containerImage)
                    .focused($editing, equals: .containerImage)
                    .onSubmit { apply(.containerImage) }
                TextField("How containers reach this Mac (empty: its LAN address)", text: $containerCallback)
                    .focused($editing, equals: .containerCallback)
                    .onSubmit { apply(.containerCallback) }
                Text(server.containersAvailable
                     ? "Sessions can run their agent in a Linux container, made by the container host, which sees the session's folder and nothing else of the Mac."
                     : "Put a container host on the PATH (\(VisorServer.containerHostName), from Visor, over Apple's container) or set one here, and turn on “Reachable from the network”, to run sessions' agents in Linux containers.")
                    .font(.caption).foregroundColor(.secondary)
            } header: {
                Text("Containers")
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
                Text("An APNs key from your Apple developer account (Keys → Apple Push Notifications service). It stays in this Mac's keychain. A push says only the session's name and what happened: \"Halo: Goal achieved in 1h45m\".")
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
        .task { remoteLogin = await Self.sshdAnswers() }
        .onAppear {
            publicAddress = server.settings.publicAddress
            tlsPath = server.settings.tlsIdentityPath
            containerHost = server.settings.containerHost.joined(separator: " ")
            containerImage = server.settings.containerImage
            containerCallback = server.settings.containerCallback
            keyID = server.apnsKey.keyID
            teamID = server.apnsKey.teamID
            draft = server.password.isEmpty ? VisorServer.generatePassword() : server.password
        }
        // Leaving a field applies it, as Return does; so does closing the
        // window with one still being edited.
        .onChange(of: editing) { left, _ in if let left { apply(left) } }
        .onDisappear {
            apply(.publicAddress)
            apply(.tlsPath)
            apply(.containerHost)
            apply(.containerImage)
            apply(.containerCallback)
        }
    }

    /// What was typed in a field, applied: on Return, on leaving the field,
    /// and when the window closes. Only a change is written: each write
    /// saves the settings and may start the listener again.
    private func apply(_ field: EditedField) {
        switch field {
        case .publicAddress:
            if server.settings.publicAddress != publicAddress { server.settings.publicAddress = publicAddress }
        case .tlsPath:
            if server.settings.tlsIdentityPath != tlsPath { server.settings.tlsIdentityPath = tlsPath }
        case .containerHost:
            let words = containerHost.split(separator: " ").map(String.init)
            if server.settings.containerHost != words {
                server.settings.containerHost = words
                Task { await server.checkContainers() }
            }
        case .containerImage:
            let image = containerImage.trimmingCharacters(in: .whitespaces)
            if server.settings.containerImage != image { server.settings.containerImage = image }
        case .containerCallback:
            let address = containerCallback.trimmingCharacters(in: .whitespaces)
            if server.settings.containerCallback != address { server.settings.containerCallback = address }
        case .tlsPassword:
            // The identity with its password, as Return always applied them.
            guard !tlsPassword.isEmpty else { return }
            server.settings.tlsIdentityPath = tlsPath
            server.setTLSPassword(tlsPassword)
        }
    }

    /// Whether something listens on this Mac's port 22: a connection
    /// tried for a moment.
    private static func sshdAnswers() async -> Bool {
        await withCheckedContinuation { done in
            let connection = NWConnection(host: "127.0.0.1", port: 22, using: .tcp)
            let answered = Mutex(false)
            let finish: @Sendable (Bool) -> Void = { up in
                guard answered.withLock({ was in defer { was = true }; return !was }) else { return }
                connection.cancel()
                done.resume(returning: up)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { finish(false) }
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

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { message = "A password is required."; return }
        server.password = trimmed
        draft = trimmed
        message = nil
    }
}
