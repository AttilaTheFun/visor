// The menu bar's menu: Visor's window first, then the server's menu as
// Visor Server had it (MenuContent: what is serving, the connection codes,
// the sessions, Settings and Quit Visor); or, while the server agent serves
// (LocalServer), the agent's (AgentServerMenu).

import SwiftUI
import VisorServer

struct VisorMenu: View {
    var local: LocalServer
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Visor") { AppDelegate.show(window: VisorMacApp.mainWindow, with: openWindow) }
            .keyboardShortcut("o")
        Divider()
        if let server = local.server {
            if let note = local.note { Text(note) }
            MenuContent(server: server)
        } else {
            AgentServerMenu(local: local)
        }
    }
}
