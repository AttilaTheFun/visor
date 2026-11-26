// Visor.app's launch, before anything of the app's (VisorMacMain): one
// instance at a time, and the app run as its own launchd agent wherever it
// can be, so launchd starts it again after a crash (AppAgentJob;
// docs/DEVELOPMENT.md, The server in the app).
//
// - A lock that can't be had at all (its file can't be opened): this copy
//   runs as a client alone, no server, and says so loudly (failing closed).
// - Another instance holds the lock (InstanceLock): this one exits 0 at
//   once, so launchd's KeepAlive doesn't start it again, and the first is
//   brought forward with its window, unless launchd started this one (a
//   crash's restart that met a person's open: the first is left as it is).
// - Opened by a person (the Finder, the Dock, Spotlight, `open`), with the
//   agent wanted (Start at Login) and the app in /Applications: launchd is
//   asked to start the app as the agent (AppAgentService.start: `launchctl
//   kickstart`, else the agent registered afresh from this bundle), and
//   this one exits 0 once that one holds the lock. If it doesn't within a
//   few seconds (Login Items waiting for the person, launchd refusing the
//   bundle), Visor runs here after all, and says why in the system log:
//   no crash restart until its next start through launchd.
// - Opened that way while an update's watch holds its lock
//   (RelaunchWatchLock, its holder checked to be that watcher:
//   RelaunchWatchHolder): the open of a build before 0.72.1's watcher,
//   which follows the app by its full path and would take a hand-off for
//   a quit (NCH's lease test of 0.72.1: 0.71.1 put back in /Applications
//   while launchd ran 0.72.1), or the server agent's watch, which the
//   hand-back waits out. Visor runs here, as the process that was opened,
//   and hands itself to launchd once the watch has ended
//   (`handsOffAfterWatch`, LocalServer: a restart through its agent).
// - Started by launchd (the agent's `VISOR_APP_AGENT`), or by the update
//   watcher's open (`--without-agent`: it asked launchd already), it runs
//   here.
// - The window: a person's open shows it, and so does launchd's process
//   that a person's open was handed to (a marker beside the lock, written
//   before launchd is asked and taken away by launchd's process), and an
//   update's relaunch when a window was open as the app went (the watcher
//   writes the same marker: AppRelauncher); launchd's own launches, at
//   login and after a crash, keep to the menu bar (AppAgentJob.showsWindow;
//   Logan, 25 Nov 2026).
// - `Visor app-agent start` (the update's watcher, AppRelauncher): the
//   same start, waited out as long as a registration takes, ending 0 once
//   launchd runs the app; 1 when it doesn't, or the agent isn't wanted (it's
//   unregistered then), for the watcher to open the app itself.
//   `Visor app-agent unregister`: unregistered.
//
// - A copy outside /Applications (a build to run here, a copy in
//   Downloads) is a client alone, with no server and no lock, unless a
//   test's or a developer's setting says it may serve
//   (AppAgentJob.clientOnly; NCH's check of #537).
//
// The screenshot fixture's runs (`-visor.fixture`) are left as they were.

import AppKit
import Foundation
import Synchronization
import VisorLaunchAgent
import VisorServerApple

@MainActor
enum MacAppInstance {
    /// Held for the process's life once Visor runs here.
    private static var held: InstanceLock?

    /// Whether this process holds the lock: the Visor an update's watch
    /// follows, and so the one whose Quit it's told of (AppAgentJob.quitMarker).
    static var holdsLock: Bool { held != nil }

    /// Posted by a second instance for the first: its window, in front.
    static let showWindow = Notification.Name("com.LoganShire.Visor.showWindow")

    /// Whether launchd started this process as the app's agent: read once,
    /// before the variable is taken out of the environment.
    private(set) static var fromAgent = false

    /// Why this copy runs no server of its own (LocalServer), if it runs
    /// none: the instance lock couldn't be had at all (failing closed), or
    /// it isn't the copy in /Applications (AppAgentJob.clientOnly).
    private(set) static var noServer: String?

    /// Whether Visor's window shows at this launch: a person's open, or
    /// one handed to launchd, does; launchd's own, at login or after a
    /// crash, keeps to the menu bar (AppAgentJob.showsWindow).
    private(set) static var showsWindow = true

    /// Whether this process was opened while an update's watch held its
    /// lock, and runs here until it ends rather than hand itself to launchd
    /// (AppAgentJob.Launch.runWhileWatched): LocalServer hands it to
    /// launchd then.
    private(set) static var handsOffAfterWatch = false

    /// The update watch's lock (RelaunchWatchLock.url), where it is before
    /// anything is settled: beside the server's data, as the watcher that
    /// took it (of this build or the one before) found it.
    static var watchLockPath: String { MacPlaces.data.appendingPathComponent("relaunch-watch.lock", isDirectory: false).path }

    /// Whether a live watcher holds the update watch's lock: its process
    /// started when the lock says (RelaunchWatchHolder), so a lock left
    /// behind whose pid names another process holds nothing.
    static func watchHeld(_ path: String) -> Bool {
        let text = try? String(contentsOfFile: path, encoding: .utf8)
        return RelaunchWatchHolder.remaining(text, now: Int(Date().timeIntervalSince1970)) != nil
    }

    /// The lock's file.
    static var lockPath: String { InstanceLock.path(bundleID: MacPlaces.own) }

    /// Runs `Visor app-agent …` when `arguments` ask for it, and never
    /// returns then; returns otherwise.
    static func handle(_ arguments: [String]) {
        let given = Array(arguments.dropFirst())
        guard given.first == AppAgentJob.command else { return }
        switch given.dropFirst().first {
        case "start":
            exit(startFromCommand() ? 0 : 1)
        case "unregister":
            let bundleID = MacPlaces.own
            let problem = finished { await AppAgentService.unregister(bundleID: bundleID) }
            if let problem {
                FileHandle.standardError.write(Data("Visor: the app's agent couldn't be unregistered: \(problem)\n".utf8))
                exit(1)
            }
            exit(0)
        default:
            FileHandle.standardError.write(Data("usage: Visor app-agent start|unregister\n".utf8))
            exit(2)
        }
    }

    /// At the launch, before the app: returns when Visor runs in this
    /// process (the lock held from then on); exits otherwise.
    static func settle(_ arguments: [String]) {
        fromAgent = ProcessInfo.processInfo.environment[AppAgentJob.environmentVariable] != nil
        unsetenv(AppAgentJob.environmentVariable)
        if arguments.contains("-visor.fixture") { return }
        let marker = AppAgentJob.presentMarker(bundleID: MacPlaces.own)
        let withoutAgent = arguments.contains(AppRelauncher.withoutAgent)
        if fromAgent || withoutAgent {
            // A person's open handed to launchd, or an update's relaunch
            // with a window open, asked for the window; taken away, so a
            // crash's restart later doesn't show it.
            let asked = AppAgentJob.askedAt(try? String(contentsOfFile: marker, encoding: .utf8))
            showsWindow = AppAgentJob.showsWindow(fromAgent: true, askedAt: asked, now: Int(Date().timeIntervalSince1970))
            try? FileManager.default.removeItem(atPath: marker)
        }
        let path = lockPath
        let installProblem = LaunchAgentJob.installProblem(LaunchAgentJob.ownExecutable)
        let launch = AppAgentJob.launch(lockHeld: heldByAnother(path), fromAgent: fromAgent,
                                        withoutAgent: withoutAgent, wanted: AppAgentService.wanted,
                                        installProblem: installProblem, watched: watchHeld(watchLockPath))
        switch launch {
        case .second(let showFirst):
            if showFirst { show(holder: InstanceLock.holder(path)) }
            NSLog("Visor: another instance runs (process %d): this one ends", InstanceLock.holder(path) ?? 0)
            exit(0)
        case .handToLaunchd:
            let bundleID = MacPlaces.own
            // launchd's process shows the window this person opened Visor for.
            try? "\(Int(Date().timeIntervalSince1970))\n".write(toFile: marker, atomically: true, encoding: .utf8)
            let started = finished {
                await AppAgentService.start(bundleID: bundleID, attempts: 1, refusedBackoff: [],
                                            started: { InstanceLock.isHeld(path) }, log: { NSLog("Visor: %@", $0) })
            }
            if started {
                NSLog("Visor: launchd runs Visor as its agent (process %d): this one ends", InstanceLock.holder(path) ?? 0)
                exit(0)
            }
            try? FileManager.default.removeItem(atPath: marker)
            NSLog("Visor: launchd didn't start Visor as its agent: it runs here, with no restart after a crash until it's next started at login")
        case .runWhileWatched:
            handsOffAfterWatch = true
            NSLog("Visor: an update's watch holds its lock: Visor runs here, the process it opened, and hands itself to launchd once the watch has ended")
        case .run:
            break
        }
        // A copy outside /Applications serves nothing of this Mac's, and
        // takes no lock: the copy in /Applications may open meanwhile.
        let servesAnyway = ProcessInfo.processInfo.environment[AppAgentJob.servesOutsideVariable] == "1"
            || UserDefaults.standard.bool(forKey: AppAgentJob.servesOutsideKey)
        if let reason = AppAgentJob.clientOnly(installProblem: installProblem, servesAnyway: servesAnyway) {
            noServer = reason
            NSLog("Visor: %@", reason)
            return
        }
        var taken: InstanceLock?
        do {
            taken = try InstanceLock.take(path)
            for _ in 0..<5 where taken == nil {
                Thread.sleep(forTimeInterval: 0.1)
                taken = try InstanceLock.take(path)
            }
        } catch {
            // Failing closed: with no lock, this copy can't know it's the
            // only one, so it runs as a client alone (LocalServer).
            let problem = "\(error)"
            noServer = problem
            NSLog("Visor: %@: Visor runs as a client alone, with no server of its own, so two servers never run on this Mac's data", problem)
            return
        }
        guard let lock = taken else {
            // launchd's process took it meanwhile, after all.
            if !fromAgent { show(holder: InstanceLock.holder(path)) }
            exit(0)
        }
        held = lock
    }

    /// Whether another instance holds the lock: held at three looks a
    /// tenth of a second apart, so an instance handing itself to launchd,
    /// which asks the lock the same way while it waits, isn't taken for one.
    private static func heldByAnother(_ path: String) -> Bool {
        for look in 0..<3 {
            guard InstanceLock.isHeld(path) else { return false }
            if look < 2 { Thread.sleep(forTimeInterval: 0.1) }
        }
        return true
    }

    /// The first instance's window, in front.
    private static func show(holder: Int32?) {
        DistributedNotificationCenter.default().postNotificationName(showWindow, object: nil, userInfo: nil, deliverImmediately: true)
        if let holder { NSRunningApplication(processIdentifier: holder)?.activate() }
    }

    /// `Visor app-agent start`: started by launchd from this bundle (the
    /// update's watcher, once the app before it has gone), or, not wanted,
    /// unregistered. Whether launchd runs it.
    private static func startFromCommand() -> Bool {
        let bundleID = MacPlaces.own
        let path = lockPath
        let log: @Sendable (String) -> Void = { print("\(Date().formatted(.iso8601)) \($0)") }
        guard AppAgentService.wanted else {
            let problem = finished { await AppAgentService.unregister(bundleID: bundleID) }
            log("the app's agent isn't wanted (Start at Login is off)\(problem.map { ": couldn't be unregistered: \($0)" } ?? ": unregistered")")
            return false
        }
        if let problem = LaunchAgentJob.installProblem(LaunchAgentJob.ownExecutable) {
            log("the app's agent isn't registered from here: \(problem)")
            return false
        }
        let started = finished { await AppAgentService.start(bundleID: bundleID, started: { InstanceLock.isHeld(path) }, log: log) }
        log(started ? "launchd runs Visor as its agent (process \(InstanceLock.holder(path) ?? 0))" : "launchd didn't start Visor as its agent")
        return started
    }

    /// `work` run to its end, from a process that has no run loop yet.
    private static func finished<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let result = Mutex<T?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let value = await work()
            result.withLock { $0 = value }
            done.signal()
        }
        done.wait()
        return result.withLock { $0 }!
    }
}
