// The menu bar app: an eye in the bar, the server underneath. The menu is
// what a client needs to connect (the connection code, the Mac's name on
// the network, the password) and what is going on (clients, sessions).
// Settings is where the password is set — it opens on its own the first
// time, because there is no serving without one — and where the
// connection code is shown as a QR code to scan and a string to copy.

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import VisorProtocol
import VisorServer

@main
struct VisorMenuBarApp: App {
    @ObservedObject private var server = VisorServer.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(server: server)
        } label: {
            Image(systemName: server.listening ? "eye" : "eye.slash")
        }
        Settings {
            SettingsPane(server: server)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The server runs from launch, whether or not the menu is ever
    /// opened — once it has a password. Without one, Settings opens.
    func applicationDidFinishLaunching(_ notification: Notification) {
        VisorServer.shared.start()
        if VisorServer.shared.password.isEmpty { Self.openSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        VisorServer.shared.endAll()
    }

    static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI's Settings scene answers the standard action.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

struct MenuContent: View {
    @ObservedObject var server: VisorServer

    var body: some View {
        Group {
            if server.password.isEmpty {
                Text("Not serving: set a password first")
                SettingsLink { Text("Set a password in Settings…") }
            } else {
                Text(server.listening ? "Visor is serving on port \(String(server.port))" : "Visor is not listening")
            }
            if let error = server.lastError { Text(error) }
            // What a client types: the tailnet name (clients connect over
            // TLS on 443, through Tailscale Serve, always).
            if let tailnetName = server.address {
                Button("\(tailnetName)") { copy(tailnetName) }
                if let serveError = server.serveError {
                    Text("HTTPS: \(serveError)")
                    Button("Retry HTTPS (\(server.exposure.title) Serve)") { server.front() }
                } else {
                    Text("HTTPS on 443 through \(server.exposure.title) Serve, this network only")
                }
                if let login = server.hostLogin {
                    Text("\(login)'s devices connect without a password")
                }
            } else {
                Text("\(server.exposure.title) is not installed — clients need its endpoint")
            }
            Divider()
            if let code = server.connectionCode {
                Button("Copy Connection Code") { copy(code.encoded) }
                Text("Paste it into Visor on a phone or another Mac, or scan the QR code in Settings")
            }
            if !server.password.isEmpty {
                Button("Password: \(server.password)") { copy(server.password) }
                Text("For a device \(server.exposure.title) does not know as yours")
                Text("Click the name or the password to copy it")
                Divider()
            }
            Text("\(server.clientCount) client\(server.clientCount == 1 ? "" : "s") connected")
            Divider()
            if server.sessions.isEmpty {
                Text("No sessions")
            } else {
                ForEach(server.sessions, id: \.info.id) { session in
                    Text("\(session.info.agent.title): \(session.info.title.isEmpty ? session.info.cwd : session.info.title)\(session.info.busy ? " …" : "")")
                }
            }
            Button("Copy session table") { copy(server.sessionTable()) }
            Divider()
            SettingsLink { Text("Settings…") }
            Button("Quit Visor") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct SettingsPane: View {
    @ObservedObject var server: VisorServer
    @State private var draft = ""
    @State private var message: String?
    @State private var linkDraft = ""
    @State private var linkMessage: String?
    @State private var linking = false
    @State private var choosingKey = false
    @State private var keyPEM = ""
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
                } else {
                    Text("HTTPS on 443 through \(server.exposure.title) Serve, reachable from this network only.")
                        .font(.caption).foregroundColor(.secondary)
                }
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
                if let name = server.exposure.address() { Text(name) }
                ForEach(VisorServer.addresses(), id: \.address) { entry in
                    Text("\(entry.address)  \(entry.name)")
                }
                Text("Port \(String(server.port)), on this Mac only; the network reaches it through the front on 443")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 760)
        .onAppear {
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

/// A QR code for a string, drawn crisp at any size (the caller turns
/// interpolation off).
enum QRCode {
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
