// The menu bar's menu while this Mac's server is the server agent
// (LocalServer): what serves, Restart Server (over its socket file), and
// Quit Visor, which quits the app alone: the server runs on. What the
// in-app menu shows besides (the codes, the password, the sessions, the
// admin token and keys) comes over the server's API in 0b.

import AppKit
import SwiftUI
import VisorLaunchAgent

struct AgentServerMenu: View {
    var local: LocalServer
    @State private var problem: String?

    var body: some View {
        switch local.mode {
        case .handingOver:
            Text("Starting this Mac's server in the background…")
        case .agent, .inApp:
            Text("This Mac's server runs in the background")
            Text("launchd: \(LocalServer.job.label)")
            if let problem { Text(problem) }
            Button("Restart Server") {
                Task { problem = await MacServerCalls.restart(installing: nil) }
            }
        }
        Divider()
        Button("Quit Visor") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
