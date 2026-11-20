// The menu bar's menu: Visor's window first, then this Mac's server's menu
// (ServerMenu: what is serving, the connection codes, the sessions,
// Settings, the server's controls and Quit Visor), whichever process runs
// it, as it says over its API.

import SwiftUI

struct VisorMenu: View {
    var local: LocalServer
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Visor") { AppDelegate.show(window: VisorMacApp.mainWindow, with: openWindow) }
            .keyboardShortcut("o")
        Divider()
        ServerMenu(local: local)
    }
}
