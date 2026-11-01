// SwiftUI's own ways to open Visor's window and Settings, handed to the
// app's AppKit code (AppDelegate) by a view that has them: AppKit has no
// other way to a SwiftUI scene. (Sending showSettingsWindow:, as Visor
// Server does, opened nothing at this app's launch on macOS 27.) The first
// time the window shows with no password set, Settings opens over it:
// there is no serving without one.

import SwiftUI
import VisorServer

struct SceneOpeners: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                AppDelegate.keep(openWindow: openWindow, openSettings: openSettings)
                if VisorServer.shared.password.isEmpty { AppDelegate.openSettings() }
            }
    }
}
