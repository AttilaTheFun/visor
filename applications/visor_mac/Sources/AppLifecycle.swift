// The server in the app's process's lifecycle (MacServer.prepare): its
// relaunches as AppRelauncher makes them; its end, once its agents are
// ended or left, answering the quit waiting on it (AppTermination), or
// quitting the app.

import AppKit
import VisorServer
import VisorServerApple

struct AppLifecycle: ServerLifecycle {
    /// Its shell's log among Visor's (MacPlaces: on the Visor volume once
    /// it's there).
    private let relauncher = AppRelauncher(logPath: MacPlaces.log("visor-relaunch.log"))

    @MainActor
    func relaunch(installing build: String?, carrying sessions: String) -> String? {
        relauncher.relaunch(installing: build, carrying: sessions)
    }

    @MainActor
    func terminate() {
        AppTermination.serverEnded = true
        if AppTermination.pending {
            AppTermination.pending = false
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        } else {
            relauncher.terminate()
        }
    }
}
