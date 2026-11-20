// Settings while this Mac's server is the server agent (LocalServer): the
// server's own settings are its, and the in-app pane (SettingsPane) edits
// a server in the app's process. Until the app is wholly the server's
// client (0b), they're changed in Visor's window (the computer's settings),
// or with the agent stopped.

import SwiftUI
import VisorLaunchAgent

struct AgentServerSettings: View {
    var local: LocalServer

    var body: some View {
        Form {
            Section {
                Text(local.mode == .handingOver
                     ? "This Mac's server is starting in the background."
                     : "This Mac's server runs in the background, as the launchd agent \(LocalServer.job.label), whether or not Visor is open.")
                Text("Its settings are in Visor's window, in this Mac's computer settings. To run the server in the app again, set the default \(ServerAgentJob.defaultsKey) off and open Visor again.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}
