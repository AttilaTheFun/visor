// The server in the app's process's lifecycle (MacServer.prepare): its
// relaunches as AppRelauncher makes them, through the app's own launchd
// agent (AppAgentJob: `Visor app-agent start`, which registers it afresh
// from the bundle in place and so starts the app as the agent, else `open
// -a`); its end, once its agents are ended or left, answering the quit
// waiting on it (AppTermination), or quitting the app. Either way the app
// exits 0, which the agent's KeepAlive leaves alone: a relaunch is its
// watcher's to start, never launchd's too.

import AppKit
import VisorLaunchAgent
import VisorServer
import VisorServerApple

struct AppLifecycle: ServerLifecycle {
    /// Its shell's log among Visor's (MacPlaces: on the Visor volume once
    /// it's there).
    private let relauncher = AppRelauncher(logPath: MacPlaces.log("visor-relaunch.log"),
                                           agent: AppRelauncher.Agent(label: AppAgentJob.label(bundleID: MacPlaces.own),
                                                                      command: [AppAgentJob.command, "start"],
                                                                      presentMarker: AppAgentJob.presentMarker(bundleID: MacPlaces.own),
                                                                      instanceLock: InstanceLock.path(bundleID: MacPlaces.own),
                                                                      quitMarker: AppAgentJob.quitMarker(bundleID: MacPlaces.own)))

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
