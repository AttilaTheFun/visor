// SwiftUI's own ways to open Visor's window and Settings, handed to the
// app's AppKit code (AppDelegate) by a view that has them: AppKit has no
// other way to a SwiftUI scene. (Sending showSettingsWindow:, as Visor
// Server does, opened nothing at this app's launch on macOS 27.) Once the
// window shows and the server has said it has no password, Settings opens
// over it (LocalServer.askForPasswordIfNeeded): there is no serving without
// one. Not on the screenshot fixture, whose computer is canned: a fresh
// Mac's proof would picture Settings instead.

import SwiftUI
import VisorClient

struct SceneOpeners: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                AppDelegate.keep(openWindow: openWindow, openSettings: openSettings)
                LocalServer.shared.askForPasswordIfNeeded()
            }
    }
}
