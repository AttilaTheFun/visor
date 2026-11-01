// The menu bar's menu: Visor's window first, then the server's menu as
// Visor Server had it (MenuContent: what is serving, the connection codes,
// the sessions, Settings and Quit Visor).

import SwiftUI
import VisorServer

struct VisorMenu: View {
    var server: VisorServer
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Visor") { AppDelegate.show(window: VisorApp.mainWindow, with: openWindow) }
            .keyboardShortcut("o")
        Divider()
        MenuContent(server: server)
    }
}
