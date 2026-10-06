import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import VisorProtocol
import VisorServer

struct MenuContent: View {
    var server: VisorServer

    var body: some View {
        Group {
            if server.password.isEmpty {
                Text("Not serving: set a password first")
                SettingsLink { Text("Set a password in Settings…") }
            } else {
                Text(server.listening ? "Visor is serving on port \(String(server.port))" : "Visor is not listening")
            }
            if let error = server.lastError { Text(error) }
            // What a client types: the address set by hand, else the
            // server's own guess when the network reaches it.
            if let address = server.reachableAddress {
                Button("\(address)") { copy(address) }
                Text(server.settings.reachableFromNetwork ? "Reachable from the network, port \(String(server.port))" : "Through a front of your own on this Mac")
            } else {
                Text("Only this Mac reaches it: open it to the network, or set an address, in Settings")
            }
            Divider()
            if let code = server.connectionCode {
                Button("Copy Connection Code") { copy(code.encoded) }
                Text("Paste it into Visor on a phone or another Mac, or scan the QR code in Settings")
            }
            if !server.password.isEmpty {
                Button("Password: \(server.password)") { copy(server.password) }
                Text("What every client signs in with")
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
            Button("Quit Visor") { server.quit() }
                .keyboardShortcut("q")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
