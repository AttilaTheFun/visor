// Settings: this Mac's server's own, as Visor Server had them (the
// connection code and its QR code, the password, the admin token, the
// network paths and TLS, agents, the Sessions container, devices, push),
// read and changed over the server's API at its socket file
// (`/api/settings`, LocalServer), whichever process runs it. A change is
// sent as it is made; what the server answers is what shows.

import AppKit
import Network
import SwiftUI
import Synchronization
import VisorClient
import VisorLaunchAgent
import VisorProtocol
import VisorServer
import VisorServerApple
import VisorSystem

struct ServerSettingsPane: View {
    var local: LocalServer
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
    enum EditedField: Hashable {
        case publicAddress, tlsPath, tlsPassword
    }
    @State private var keyID = ""
    @State private var teamID = ""
    @State private var pushMessage: String?
    /// The fields filled from the server once, when it first answers.
    @State private var filled = false

    var body: some View {
        Group {
            if let controls = local.controls {
                form(controls)
            } else {
                Form {
                    Section {
                        Text(local.mode == .handingOver ? "This Mac's server is starting in the background."
                                                        : "This Mac's server isn't answering\(local.unreachable.map { ": \($0)" } ?? ".")")
                        if local.mode == .agent {
                            Button("Start Server") { Task { message = await local.startServer() } }
                        }
                        if let message { Text(message).font(.caption).foregroundColor(.red) }
                    }
                }
                .formStyle(.grouped)
                .frame(width: 520)
                .padding()
            }
        }
        .task { await local.refresh() }
    }

    private func form(_ controls: ServerControls) -> some View {
        Form {
            connectSection(controls)
            passwordSection(controls)
            adminTokenSection(controls)
            pathsSection(controls)
            agentsSection(controls)
            ContainerSettingsSection(settings: controls.settings, client: local.client, send: send)
            devicesSection(controls)
            pushSection(controls)
            if local.mode == .agent || local.note != nil { backgroundSection }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 760)
        .task { remoteLogin = await Self.sshdAnswers() }
        .onAppear { fill(controls) }
        // Leaving a field applies it, as Return does; so does closing the
        // window with one still being edited.
        .onChange(of: editing) { left, _ in if let left { apply(left) } }
        .onDisappear {
            apply(.publicAddress)
            apply(.tlsPath)
        }
    }

    /// The fields as the server has them, the first time it answers.
    private func fill(_ controls: ServerControls) {
        guard !filled else { return }
        filled = true
        publicAddress = controls.settings.publicAddress
        tlsPath = controls.settings.tlsIdentityPath
        keyID = controls.apnsKeyID
        teamID = controls.apnsTeamID
        draft = controls.password.isEmpty ? VisorServer.generatePassword() : controls.password
    }

    private func connectSection(_ controls: ServerControls) -> some View {
        Section {
            if let codes = controls.codes {
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
                                Button("Copy \(kind.title) Code") { copy(code) }
                            }
                        }
                    }
                }
                Text("The code holds this Mac's address and password: share it only with your own devices. Each copy leads with that kind of path (the others follow it); a device that has this Mac shows the same codes in its settings, to hand it on.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Text(controls.password.isEmpty ? "Set a password below to get a connection code." : "Open the server to the network, or set an address, below, to get a connection code.")
                    .font(.caption).foregroundColor(.secondary)
            }
        } header: {
            Text("Connect a device")
        }
    }

    private func passwordSection(_ controls: ServerControls) -> some View {
        Section {
            TextField("Required", text: $draft)
            HStack {
                Button("Save") { save() }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || draft == controls.password)
                    .keyboardShortcut(.defaultAction)
                Button("Generate") { draft = VisorServer.generatePassword() }
            }
            Text(controls.password.isEmpty
                 ? "Visor does not serve until a password is set. Every client and every tool on this Mac signs in with it; the connection code carries it."
                 : "Clients that are already connected stay connected; new logins use the new password.")
                .font(.caption).foregroundColor(.secondary)
            if let message { Text(message).font(.caption).foregroundColor(.red) }
            Picker("Clients show", selection: Binding(get: { controls.settings.authentication },
                                                       set: { send(ServerControlsChange(authentication: $0)) })) {
                Text("The password").tag("password")
                Text("Nothing").tag("none")
            }
            Text(controls.settings.asksNothing
                 ? "Anyone who reaches the server is let in: keep it to paths of your own — this Mac, a VPN of yours, SSH, or a front that signs users in before it reaches Visor."
                 : "A client signs in with the password (or a token it was given for it); SSH clients at the socket file need neither.")
                .font(.caption).foregroundColor(.secondary)
        } header: {
            Text("Password")
        }
    }

    private func adminTokenSection(_ controls: ServerControls) -> some View {
        Section {
            Button("Create Admin Token…") { Task { await ServerTokenAlerts.create(local) } }
                .disabled(controls.hasAdminToken)
            Text(controls.hasAdminToken
                 ? "There is an admin token. Rotate it with the current one (visor-server admin-token rotate), or reset it from the menu."
                 : "A token for the admin side over REST (Authorization: Bearer), beside the password: for deploys, restarts and backups. "
                    + "Shown once; only its hash is kept.")
                .font(.caption).foregroundColor(.secondary)
        } header: {
            Text("Admin token")
        }
    }

    private func pathsSection(_ controls: ServerControls) -> some View {
        Section {
            let addresses = NetworkAddresses.all().map { NetworkAddress(address: $0.address, interface: $0.name) }
            let scheme = controls.servesTLS ? "https" : "http"
            pathRow("http://127.0.0.1:\(String(controls.port))")
            Text("This Mac: always on, for its own Visor and its agents' tools.").font(.caption).foregroundColor(.secondary)
            Toggle("LAN", isOn: Binding(get: { controls.settings.lan }, set: { send(ServerControlsChange(lan: $0)) }))
            if controls.settings.lan {
                ForEach(addresses.filter { $0.kind == .lan }, id: \.address) { entry in
                    pathRow("\(scheme)://\(entry.address):\(String(controls.port))", note: entry.interface)
                }
            }
            Toggle("VPN", isOn: Binding(get: { controls.settings.vpn }, set: { send(ServerControlsChange(vpn: $0)) }))
            if controls.settings.vpn {
                ForEach(addresses.filter { $0.kind == .vpn }, id: \.address) { entry in
                    pathRow("\(scheme)://\(entry.address):\(String(controls.port))", note: entry.interface)
                }
            }
            Toggle("SSH", isOn: Binding(get: { controls.settings.sshEnabled }, set: { send(ServerControlsChange(sshEnabled: $0)) }))
            if controls.settings.sshEnabled {
                ForEach(controls.sshPaths, id: \.self) { path in pathRow(path) }
                if remoteLogin == false {
                    Text("Remote Login is off on this Mac, so nothing reaches these yet: turn it on in System Settings → General → Sharing.")
                        .font(.caption).foregroundColor(.red)
                } else {
                    Text("Through this Mac's Remote Login, as you: no password asked (the socket file \(VisorServer.socketPath)).")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Toggle("Reverse proxy", isOn: Binding(get: { controls.settings.proxyEnabled }, set: { send(ServerControlsChange(proxyEnabled: $0)) }))
            if controls.settings.proxyEnabled {
                TextField("https://proxy.example.com/visor", text: $publicAddress)
                    .focused($editing, equals: .publicAddress)
                    .onSubmit { apply(.publicAddress) }
                if !controls.settings.publicAddress.isEmpty { pathRow(controls.settings.publicAddress) }
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
            Text(controls.servesTLS ? "Serving TLS with the identity above." : "Serving plain TCP: TLS, if any, is the front's. A field applies on Return, or on leaving it.")
                .font(.caption).foregroundColor(.secondary)
            if let error = controls.lastError { Text(error).font(.caption).foregroundColor(.red) }
        } header: {
            Text("Network paths")
        }
    }

    private func agentsSection(_ controls: ServerControls) -> some View {
        Section {
            // Set in the server's environment, the environment's word stands.
            let given = controls.detachingSet
            Toggle("Run agents apart from the server", isOn: Binding(get: { given ?? controls.settings.detachAgents },
                                                                      set: { send(ServerControlsChange(detachAgents: $0)) }))
                .disabled(given != nil)
            Text(given != nil
                 ? "Set by VISOR_DETACH_AGENT_HOST in the server's environment."
                 : "Each session's agent runs under a host of its own, so restarting or updating the server leaves it working, and one that runs away cannot take the server down. Off, agents are the server's own children: a restart stops them. Applies to agents started from now on.")
                .font(.caption).foregroundColor(.secondary)
        } header: {
            Text("Agents")
        }
    }

    private func devicesSection(_ controls: ServerControls) -> some View {
        Section {
            Toggle("Let devices keep messages on disk", isOn: Binding(get: { controls.settings.clientsKeepMessages },
                                                                      set: { send(ServerControlsChange(clientsKeepMessages: $0)) }))
            Text(controls.settings.clientsKeepMessages
                 ? "A device keeps the sessions' messages it has seen, so a session opens as last seen and reads back offline."
                 : "A device holds only the pages it shows, in memory, and asks again for those it let go of; what it kept on disk goes the next time it signs in.")
                .font(.caption).foregroundColor(.secondary)
        } header: {
            Text("Devices")
        }
    }

    private func pushSection(_ controls: ServerControls) -> some View {
        Section {
            Text(controls.apnsConfigured
                 ? "Key \(controls.apnsKeyID) is set; \(controls.pushDevices) device\(controls.pushDevices == 1 ? "" : "s") asked for notifications."
                 : "Not set up: phones hear of finished turns only while Visor is open.")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Button(keyPEM.isEmpty ? "Choose APNs Key (.p8)…" : "Key chosen") { choosingKey = true }
                Spacer()
                Button("Send Test") { Task { pushMessage = await testPush() } }
                    .disabled(!controls.apnsConfigured)
            }
            TextField("Key ID", text: $keyID)
            TextField("Team ID", text: $teamID)
            Button("Save Key") { Task { await saveKey() } }
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

    private var backgroundSection: some View {
        Section {
            if let note = local.note { Text(note).font(.caption) }
            Text(local.mode == .agent
                 ? "This Mac's server runs in the background, as the launchd agent \(LocalServer.job.label), whether or not Visor is open. Quitting Visor leaves it serving; the menu's Stop Server stops it."
                 : "This Mac's server runs in Visor itself, and stops when Visor quits.")
            Text("Set the default \(ServerAgentJob.defaultsKey) on or off, and open Visor again, to change where it runs.")
                .font(.caption).foregroundColor(.secondary)
        } header: {
            Text("Where it runs")
        }
    }

    /// A change sent to the server; what it refused shown.
    private func send(_ change: ServerControlsChange) {
        Task { if let problem = await local.change(change) { message = problem } }
    }

    /// What was typed in a field, applied: on Return, on leaving the field,
    /// and when the window closes. Only a change is sent: each may start
    /// the listener again.
    private func apply(_ field: EditedField) {
        guard let settings = local.controls?.settings else { return }
        switch field {
        case .publicAddress:
            if settings.publicAddress != publicAddress { send(ServerControlsChange(publicAddress: publicAddress)) }
        case .tlsPath:
            if settings.tlsIdentityPath != tlsPath { send(ServerControlsChange(tlsIdentityPath: tlsPath)) }
        case .tlsPassword:
            // The identity with its password, as Return always applied them.
            guard !tlsPassword.isEmpty else { return }
            send(ServerControlsChange(tlsIdentityPath: tlsPath, tlsPassword: tlsPassword))
        }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { message = "A password is required."; return }
        draft = trimmed
        message = nil
        send(ServerControlsChange(password: trimmed))
    }

    private func testPush() async -> String {
        do {
            try await local.client.sendTestPush()
            return "Sent."
        } catch {
            return VisorAgentServer.problem(error)
        }
    }

    private func saveKey() async {
        do {
            try await local.client.setPushKey(pem: keyPEM, keyID: keyID.trimmingCharacters(in: .whitespaces),
                                              teamID: teamID.trimmingCharacters(in: .whitespaces))
            pushMessage = "Saved."
            keyPEM = ""
            await local.refresh()
        } catch {
            pushMessage = VisorAgentServer.problem(error)
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
            Button("Copy") { copy(path) }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
