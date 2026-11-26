// Visor.app's own launchd agent (0.72.1; docs/DEVELOPMENT.md, The server
// in the app). Logan, 25 Nov 2026: "The background process IS the menu-bar
// app, so that I can always tell when it's running, and its windows are
// the clients." The server runs in the app's process; this agent is what
// starts the app at login and again after a crash.
//
// - `<bundle id>.app` (`com.LoganShire.Visor.app`): its plist is the app
//   bundle's own (`Contents/Library/LaunchAgents/<label>.plist`), registered
//   with SMAppService.agent (AppAgentService), its program the app's own
//   executable with no argument: the app itself, menu bar and all, as a
//   person opens it.
// - RunAtLoad: started at login. KeepAlive after a failure only: a crash
//   (a signal, or an exit that isn't 0) is started again; Quit Visor (an
//   exit of 0), or a relaunch making way for its update (the watcher starts
//   it: AppRelauncher), is left alone.
// - LimitLoadToSessionType Aqua: only in a person's graphical session.
//   ProcessType Interactive: not throttled as a background job is.
// - AbandonProcessGroup: the agents' hosts and the update's watcher are its
//   children, and outlive it.
// - `VISOR_APP_AGENT` in its environment: the app knows launchd started it
//   (`fromAgent`), and takes it out of its own environment at once, so
//   nothing it starts inherits it.
//
// One instance at a time (InstanceLock): launchd's start after a crash and
// a person's open can meet. What a launch does is `launch`'s, below. The
// `StartsAtLogin` default (on unless set off: the menu's Start at Login)
// says whether the agent is wanted.

import Foundation

public enum AppAgentJob {
    /// The variable launchd gives the app in the agent's environment.
    public static let environmentVariable = "VISOR_APP_AGENT"
    /// The app's default (`defaults write com.LoganShire.Visor
    /// StartsAtLogin -bool false`) that has no agent registered.
    public static let defaultsKey = "StartsAtLogin"
    /// The app's command (`Visor app-agent start`): the agent registered
    /// afresh from this bundle, which starts the app, and ends; what the
    /// update's watcher runs to start the new build (AppRelauncher).
    public static let command = "app-agent"

    /// `<bundle id>.app`.
    public static func label(bundleID: String) -> String { bundleID + ".app" }
    /// The plist's name in the bundle's `Contents/Library/LaunchAgents`, as
    /// SMAppService.agent(plistName:) takes it.
    public static func plistName(bundleID: String) -> String { label(bundleID: bundleID) + ".plist" }

    /// Whether the agent is wanted, from the default as set (nil: never
    /// set, which is on).
    public static func wanted(_ setting: Bool?) -> Bool { setting ?? true }

    /// The plist the app bundle carries (applications/visor_mac/LaunchAgents,
    /// checked against this by //tests/visor_launch_agent_tests): its
    /// program the bundle's own executable, alone, as SMAppService runs it.
    public static func bundledPlist(bundleID: String, executable: String = "Visor") -> [String: Any] {
        [
            "Label": label(bundleID: bundleID),
            "BundleProgram": "Contents/MacOS/\(executable)",
            "ProgramArguments": ["Contents/MacOS/\(executable)"],
            "AssociatedBundleIdentifiers": [bundleID],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "ExitTimeOut": 30,
            "ThrottleInterval": 10,
            "AbandonProcessGroup": true,
            "EnvironmentVariables": [environmentVariable: "1"],
        ]
    }

    /// Why a copy of the app runs as a client alone, with no server of its
    /// own, or nil when it may serve (NCH's check of #537): one outside
    /// /Applications (a build to run here, a copy in Downloads) would
    /// otherwise serve this Mac's own data whenever nothing holds the lock.
    /// `servesAnyway`: a test's or a developer's setting says it may
    /// (`ServesOutsideApplications`, VISOR_SERVE_OUTSIDE_APPLICATIONS=1).
    public static func clientOnly(installProblem: String?, servesAnyway: Bool) -> String? {
        guard let installProblem, !servesAnyway else { return nil }
        return "this copy of Visor isn't the one in /Applications (\(installProblem)), so it's a client alone, with no server of "
            + "its own on this Mac's data (for a build to run here: defaults write com.LoganShire.Visor \(servesOutsideKey) -bool true)"
    }

    /// The app's default, and the variable, that let a copy outside
    /// /Applications serve (a build to run here; CI's launch check).
    public static let servesOutsideKey = "ServesOutsideApplications"
    public static let servesOutsideVariable = "VISOR_SERVE_OUTSIDE_APPLICATIONS"

    /// What a launch of the app does, before anything else.
    public enum Launch: Equatable, Sendable {
        /// Another instance holds the lock: this one ends at once, with an
        /// exit of 0 (so KeepAlive doesn't start it again), the first shown
        /// in front unless launchd started this one (a crash's restart that
        /// met a person's open).
        case second(showFirst: Bool)
        /// Visor runs in this process.
        case run
        /// The agent is wanted and this process isn't launchd's: launchd is
        /// asked to start the app as the agent (so a crash of it is started
        /// again), and this one ends once that one holds the lock; if it
        /// doesn't, Visor runs here after all.
        case handToLaunchd
        /// As `handToLaunchd`, but an update's watch holds its lock
        /// (RelaunchWatchLock): one from a build before 0.72.1, whose
        /// watcher opened this process and follows it by its full path, so
        /// a hand-off would read to it as a quit and undo the update over
        /// launchd's copy (NCH's lease test of 0.72.1). Visor runs here,
        /// and hands itself to launchd once the watch has ended
        /// (LocalServer: a restart through its agent).
        case runWhileWatched
    }

    /// What a launch does:
    ///
    /// | lock held by another | started by           | agent wanted, app in /Applications | launch        |
    /// |----------------------|----------------------|------------------------------------|---------------|
    /// | yes                  | launchd              | any                                | second, quiet |
    /// | yes                  | a person             | any                                | second, shown |
    /// | yes                  | a watcher's open     | any                                | second, quiet |
    /// | no                   | launchd              | any                                | run           |
    /// | no                   | a watcher's open     | any                                | run           |
    /// | no                   | a person, no watch   | yes                                | handToLaunchd |
    /// | no                   | a person, a watch    | yes                                | runWhileWatched |
    /// | no                   | a person             | no                                 | run           |
    ///
    /// A watcher's open (`--without-agent`: AppRelauncher's) is its
    /// fallback once launchd didn't start the app, so it runs where it is.
    /// A relaunch's open from a build before 0.72.1 looks like a person's,
    /// but its watcher holds the update watch's lock (`watched`): the app
    /// it opens stays the process it opened while the watch lasts, then
    /// hands itself to launchd (NCH's lease test of 0.72.1: 0.71.1's
    /// watcher, which follows the app by its full path, took the hand-off
    /// for a quit and put 0.71.1 back while launchd ran 0.72.1). The
    /// server agent's watch (an update from a build before 0.72.1 that
    /// ran its server as the agent) holds the same lock: the app runs here
    /// through the hand-back too, then hands itself to launchd the same
    /// way, so neither hand-off falls inside a watch.
    ///
    /// A second instance started by launchd or by a watcher's open is
    /// quiet (NCH's check of #537): mid-update, the window is the present
    /// marker's to ask for alone, never a copy that lost the race.
    public static func launch(lockHeld: Bool, fromAgent: Bool, withoutAgent: Bool, wanted: Bool, installProblem: String?,
                              watched: Bool = false) -> Launch {
        if lockHeld { return .second(showFirst: !(fromAgent || withoutAgent)) }
        if fromAgent || withoutAgent { return .run }
        guard wanted, installProblem == nil else { return .run }
        return watched ? .runWhileWatched : .handToLaunchd
    }

    /// What the app that runs while a watch lasted (`runWhileWatched`)
    /// does about launchd, at each look.
    public enum HandOff: Equatable, Sendable {
        /// Looks again: the watch still runs (a live watcher holds its
        /// lock), or the server doesn't run in this process yet (the
        /// hand-back: a restart asked then would reach the server agent).
        case wait
        /// Hands itself to launchd now: a restart through its agent.
        case now
        /// Never: the agent isn't wanted any more (Start at Login turned
        /// off meanwhile), or this copy may not register it.
        case never
    }

    public static func handOff(watching: Bool, serverInApp: Bool, wanted: Bool, installProblem: String?) -> HandOff {
        guard wanted, installProblem == nil else { return .never }
        return !watching && serverInApp ? .now : .wait
    }

    /// How often the app that runs while a watch lasts looks at it, and how
    /// many times a hand-off that's refused (a restart answered 409, the
    /// server not yet up) is asked again.
    public static let watchPoll: Duration = .seconds(5)
    public static let handOffTries = 6

    /// Whether the window shows at the launch (Logan, 25 Nov 2026: at login
    /// and after a crash, the menu bar alone):
    ///
    /// | started by                                       | window |
    /// |--------------------------------------------------|--------|
    /// | a person (the Finder, the Dock, `open`)          | yes    |
    /// | launchd, at login or after a crash               | no     |
    /// | launchd, handed a person's open (`askedAt`)      | yes    |
    /// | an update's relaunch, a window open (`askedAt`)  | yes    |
    /// | an update's relaunch, no window open             | no     |
    ///
    /// A person's open handed to launchd, or an update's relaunch with a
    /// window open (its watcher, just before it starts the app: AppRelauncher),
    /// leaves a marker first, the time it was written (`presentMarker`),
    /// which the process started (launchd's, or the watcher's open) reads and
    /// takes away; one older than `presentWithin` seconds (a hand-off that
    /// came to nothing), or from the future, says nothing.
    public static func showsWindow(fromAgent: Bool, askedAt: Int?, now: Int) -> Bool {
        guard fromAgent else { return true }
        guard let askedAt else { return false }
        return askedAt <= now && now - askedAt <= presentWithin
    }

    /// How long a marker holds: longer than a start through launchd takes
    /// (a registration afresh, its refusals waited out: about two minutes
    /// at most after an update).
    public static let presentWithin = 180

    /// The marker of a person's open handed to launchd: beside the instance
    /// lock, in this user's temporary folder.
    public static func presentMarker(bundleID: String, temporary: String = InstanceLock.userTemporaryFolder) -> String {
        (temporary as NSString).appendingPathComponent(bundleID + ".present")
    }

    /// The time a marker says it was written (seconds since 1970); nil when
    /// it says nothing readable.
    public static func askedAt(_ text: String?) -> Int? {
        text.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// The pauses a handing to launchd gives launchd's process to take the
    /// lock: about 5 seconds.
    public static let handPolls = 25
    public static let handPoll: Duration = .milliseconds(200)
}
