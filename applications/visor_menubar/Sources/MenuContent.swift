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
                Button("Set a password in Settings…") { AppDelegate.openSettings() }
            } else {
                Text(server.listening ? "Visor is serving on port \(String(server.port))" : "Visor is not listening")
            }
            if let error = server.lastError { Text(error) }
            // What a client types: the address set by hand, else the
            // server's own guess when the network reaches it.
            if let address = server.reachableAddress {
                Button("\(address)") { copy(address) }
                Text("What clients are told; every network path is in Settings")
            } else {
                Text("Only this Mac and SSH reach it: open a network path in Settings")
            }
            Divider()
            if let codes = server.connectionCodes {
                Button("Show QR Code…") { AppDelegate.openSettings() }
                ForEach(ConnectionPath.allCases, id: \.self) { kind in
                    if let code = codes.code(for: kind) { Button("Copy \(kind.title) Connection Code") { copy(code) } }
                }
                Text("Scan it, or paste a code into Visor on a phone or another Mac")
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
            // Not SettingsLink: it opens the window behind other apps'.
            Button("Settings…") { AppDelegate.openSettings() }
                .keyboardShortcut(",")
            Button("Quit Visor") { server.quit() }
                .keyboardShortcut("q")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
