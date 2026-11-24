// The menu bar app relaunched into its bundle on disk once that is another
// build (AppRelaunchCheck, which decides). An update replaces Visor.app and
// restarts the server agent, but not the app (0.64.1's and 0.65.1's ran on
// for days beside a 0.69.1 server, and Shireworks was never told the build
// installed: VisorUpdates writes that at the app's start). Looked at when
// the app learns the server restarted (LocalServer: it answers again after
// it didn't, or with another version), and every few minutes besides.
//
// Only while the server agent serves: the app is its client then, and
// quits alone (AppDelegate.applicationShouldTerminate), the agent and its
// sessions running on. With the server in the app's own process, its
// relaunch is the server's (AppRelauncher). Not while the app installs an
// update itself (LocalServer.install), which reopens it at its end, nor
// while the app is in front: it waits until it isn't.
//
// The relaunch is LocalServer.reopen's: a shell waits for this process to
// end, then opens the bundle, so there are never two of the app at once.

import AppKit
import Foundation
import VisorClient
import VisorLaunchAgent
import VisorServer

@MainActor
enum MacAppRelaunch {
    /// How often it's looked at besides.
    static let interval: Duration = .seconds(300)
    /// How soon it's looked at again while the app is in front.
    static let inFront = 60

    /// The build this process runs: its Info.plist as loaded at launch.
    static let running = AppRelaunchCheck.Build(info: Bundle.main.infoDictionary ?? [:])

    private static var periodic: Task<Void, Never>?
    private static var again: Task<Void, Never>?
    /// The last stay said in the log, so the periodic look doesn't repeat it.
    private static var said: String?

    /// At launch: the build running taken now, and the periodic look.
    static func start() {
        guard periodic == nil, !VisorFixture.active else { return }
        log("app relaunch: this process runs \(running.title) from \(Bundle.main.bundlePath)")
        periodic = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                check("every \(interval.components.seconds / 60) minutes")
            }
        }
    }

    /// Looked at now (`moment`: why now, for the log); relaunched if
    /// AppRelaunchCheck says so.
    static func check(_ moment: String) {
        guard !VisorFixture.active, !LocalServer.shared.reopening, LocalServer.shared.mode == .agent else { return }
        guard !LocalServer.shared.installing else {
            say("app relaunch (\(moment)): not now: the app is installing an update itself, and reopens at its end")
            return
        }
        let bundle = Bundle.main.bundlePath
        let lock = try? String(contentsOf: RelaunchWatchLock.url, encoding: .utf8)
        let watchLeft = AppRelaunchCheck.watchLeft(lock: lock, now: Int(Date().timeIntervalSince1970),
                                                   isRunning: { ServerPlatform.current.processes.isRunning($0) })
        var decision = AppRelaunchCheck.decide(running: running, inApplications: AppRelaunchCheck.inApplications(bundle),
                                               onDisk: AppRelaunchCheck.onDisk(bundle), watchLeft: watchLeft)
        if case .relaunch(let why) = decision, NSApp.isActive {
            decision = .later("\(why), but the app is in front", seconds: inFront)
        }
        switch decision {
        case .stay(let why):
            say("app relaunch (\(moment)): no: \(why)")
        case .later(let why, let seconds):
            say("app relaunch (\(moment)): not yet: \(why); looked at again in \(seconds) s")
            lookAgain(in: seconds + 5)
        case .relaunch(let why):
            log("app relaunch (\(moment)): \(why): the app reopens from \(bundle); the server agent runs on")
            LocalServer.shared.reopen()
        }
    }

    /// Said in the log once, until something else is.
    private static func say(_ line: String) {
        guard line != said else { return }
        said = line
        log(line)
    }

    /// The app's log (the system log's, with Visor's other lines).
    private static func log(_ line: String) {
        ServerPlatform.current.log(line)
    }

    /// One more look, `seconds` on (the latest asked for).
    private static func lookAgain(in seconds: Int) {
        again?.cancel()
        again = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            check("looked at again")
        }
    }
}
