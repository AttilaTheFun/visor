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
                    Text("The code holds this Mac's Tailscale name and password: share it only with your own devices.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text(server.password.isEmpty ? "Set a password below to get a connection code." : "Waiting for \(server.exposure.title) to name this Mac…")
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
                     ? "Visor does not serve until a password is set. Your own devices on your \(server.exposure.title) network get in without it; it is for a device \(server.exposure.title) does not know as yours, and for tools on this Mac."
                     : "Clients that are already connected stay connected; new logins use the new password.")
                    .font(.caption).foregroundColor(.secondary)
                if let message { Text(message).font(.caption).foregroundColor(.red) }
            } header: {
                Text("Password")
            }
            Section {
                if let login = server.hostLogin {
                    Text("This Mac belongs to \(login) on \(server.exposure.title). Devices signed in as \(login) are let in without the password.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text("\(server.exposure.title) has not said whose this Mac is; clients will need the password.")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let serveError = server.serveError {
                    Text("HTTPS: \(serveError)").font(.caption).foregroundColor(.red)
                    Button("Retry") { server.front() }
                } else if server.frontedElsewhere {
                    Text("Reached through a front of your own: clients take the address below. \(server.exposure.title) Serve is not needed for it.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text("HTTPS on 443 through \(server.exposure.title) Serve, reachable from this network only.")
                        .font(.caption).foregroundColor(.secondary)
                }
                TextField("Address for a front of your own (https://proxy.example.com/visor)", text: $publicAddress)
                    .onSubmit { server.publicAddress = publicAddress; server.front() }
                Text("Leave it empty to use \(server.exposure.title)'s name. Set it when a reverse proxy or a tunnel fronts this Mac at one address, sending /api to port \(String(server.port + 1)) and everything else to port \(String(server.port)): the connection code then carries that address. A front that passes no WebSockets still works; clients poll instead.")
                    .font(.caption).foregroundColor(.secondary)
            } header: {
                Text("Network")
            }
            Section {
                ForEach(server.links, id: \.host) { link in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(link.name)
                            Text(link.host).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Unlink") { server.unlink(host: link.host) }
                    }
                }
                HStack {
                    TextField("Another computer's connection code", text: $linkDraft)
                    Button("Link") { link() }
                        .disabled(linking || linkDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("The agents here can list, message and read the sessions on linked computers, and theirs the ones here. Paste the code on either computer: the link goes both ways.")
                    .font(.caption).foregroundColor(.secondary)
                if let linkMessage { Text(linkMessage).font(.caption).foregroundColor(.red) }
            } header: {
                Text("Linked computers")
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
            Section("Addresses") {
                if let name = server.address { Text(name) }
                ForEach(NetworkAddresses.all(), id: \.address) { entry in
                    Text("\(entry.address)  \(entry.name)")
                }
                Text("Port \(String(server.port)), on this Mac only; the network reaches it through the front on 443")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 760)
        .onAppear {
            publicAddress = server.publicAddress
            keyID = server.apnsKey.keyID
            teamID = server.apnsKey.teamID
            draft = server.password.isEmpty ? VisorServer.generatePassword() : server.password
        }
    }

    private func link() {
        linking = true
        linkMessage = nil
        Task {
            linkMessage = await server.link(linkDraft)
            // Kept here, even if the other did not link back: the code is done with.
            if let code = ConnectionCode(parsing: linkDraft), server.links.contains(where: { $0.host == code.host }) { linkDraft = "" }
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
