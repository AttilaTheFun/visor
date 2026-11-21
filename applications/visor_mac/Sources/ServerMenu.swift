// This Mac's server's menu, as Visor Server had it (what is serving, the
// connection codes, the password to copy, the clients and sessions, the
// admin token and signing keys, Settings), all from the server's API at its
// socket file (LocalServer), whichever process runs it. The server agent's
// has Restart Server and Stop Server too, and Quit Visor quits the app
// alone; in the app's process, Quit Visor stops the server with it.

import AppKit
import SwiftUI
import VisorClient
import VisorProtocol

struct ServerMenu: View {
    var local: LocalServer
    @State private var problem: String?

    var body: some View {
        Group {
            if let note = local.note { Text(note) }
            if local.mode == .handingOver {
                Text("Starting this Mac's server in the background…")
            } else if let controls = local.controls {
                serving(controls)
            } else {
                Text("This Mac's server isn't answering")
                if let unreachable = local.unreachable { Text(unreachable) }
                if local.mode == .agent {
                    Button("Start Server") { act { await local.startServer() } }
                }
            }
            if let problem { Text(problem) }
            Divider()
            // Not SettingsLink: it opens the window behind other apps'.
            Button("Settings…") { AppDelegate.openSettings() }
                .keyboardShortcut(",")
            Button("Quit Visor") { local.quitApp() }
                .keyboardShortcut("q")
        }
        .task { await local.refresh() }
    }

    @ViewBuilder
    private func serving(_ controls: ServerControls) -> some View {
        if !controls.hasPassword {
            Text("Not serving: set a password first")
            Button("Set a password in Settings…") { AppDelegate.openSettings() }
        } else {
            Text(controls.listening ? "Visor is serving on port \(String(controls.port))" : "Visor is not listening")
        }
        if local.mode == .agent { Text("In the background (\(LocalServer.job.label)), \(controls.version)") }
        if let error = controls.lastError { Text(error) }
        if let notice = controls.updateNotice { Text(notice) }
        // What a client types: the address set by hand, else the server's
        // own guess when the network reaches it.
        if let address = controls.reachableAddress {
            Button("\(address)") { copy(address) }
            Text("What clients are told; every network path is in Settings")
        } else {
            Text("Only this Mac and SSH reach it: open a network path in Settings")
        }
        Divider()
        if let codes = controls.codes {
            Button("Show QR Code…") { AppDelegate.openSettings() }
            ForEach(ConnectionPath.allCases, id: \.self) { kind in
                if let code = codes.code(for: kind) { Button("Copy \(kind.title) Connection Code") { copy(code) } }
            }
            Text("Scan it, or paste a code into Visor on a phone or another Mac")
        }
        // Never shown in the menu (it is open on a shared screen as much as
        // anywhere): copied for whoever needs it.
        if !controls.password.isEmpty {
            Button("Copy Password") { copy(controls.password) }
            Text("What every client signs in with")
            Divider()
        }
        Text("\(controls.clientCount) client\(controls.clientCount == 1 ? "" : "s") connected")
        Divider()
        // The active sessions alone: an archived one is the Sessions list's
        // Archived section's, not the menu's.
        let active = local.sessions.filter { !$0.archived }
        if active.isEmpty {
            Text("No active sessions")
        } else {
            ForEach(active, id: \.id) { session in
                Text("\(session.agent.title): \(session.title.isEmpty ? session.cwd : session.title)\(session.busy ? " …" : "")")
            }
        }
        Button("Copy session table") {
            act {
                do {
                    copy(try await local.client.sessionTable())
                    return nil
                } catch {
                    return VisorAgentServer.problem(error)
                }
            }
        }
        Divider()
        // The admin token is reset, and the signing keys dropped in an
        // emergency, from here alone on a Mac (ServerTokenAlerts).
        Button("Reset Admin Token…") { Task { await ServerTokenAlerts.reset(local) } }
        Button("Rotate Signing Keys") { Task { await ServerTokenAlerts.rotateKeys(local, emergency: false) } }
        Button("Emergency Key Rotation…") { Task { await ServerTokenAlerts.rotateKeys(local, emergency: true) } }
        if local.mode == .agent {
            Divider()
            Button("Restart Server") { act { await local.restartServer() } }
            Button("Stop Server") { act { await local.stopServer() } }
        }
    }

    /// Something the server is asked: what went wrong, shown in the menu.
    private func act(_ asking: @escaping @MainActor () async -> String?) {
        Task { problem = await asking() }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
