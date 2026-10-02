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
