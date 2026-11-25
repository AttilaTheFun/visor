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
    }

    /// What a launch does:
    ///
    /// | lock held by another | started by           | agent wanted, app in /Applications | launch        |
    /// |----------------------|----------------------|------------------------------------|---------------|
    /// | yes                  | launchd              | any                                | second, quiet |
    /// | yes                  | a person, a relaunch | any                                | second, shown |
    /// | no                   | launchd              | any                                | run           |
    /// | no                   | a watcher's open     | any                                | run           |
    /// | no                   | a person             | yes                                | handToLaunchd |
    /// | no                   | a person             | no                                 | run           |
    ///
    /// A watcher's open (`--without-agent`: AppRelauncher's) is its
    /// fallback once launchd didn't start the app, so it runs where it is.
    /// A relaunch's open from a build before 0.72.1 is a person's: the app
    /// it opens hands itself to launchd, registering the agent.
    public static func launch(lockHeld: Bool, fromAgent: Bool, withoutAgent: Bool, wanted: Bool, installProblem: String?) -> Launch {
        if lockHeld { return .second(showFirst: !fromAgent) }
        if fromAgent || withoutAgent { return .run }
        guard wanted, installProblem == nil else { return .run }
        return .handToLaunchd
    }

    /// Whether the window shows at the launch (Logan, 25 Nov 2026: at login
    /// and after a crash, the menu bar alone):
    ///
    /// | started by                                  | window |
    /// |---------------------------------------------|--------|
    /// | a person (the Finder, the Dock, `open`)     | yes    |
    /// | launchd, at login or after a crash          | no     |
    /// | launchd, handed a person's open (`askedAt`) | yes    |
    ///
    /// A person's open handed to launchd leaves a marker first, the time it
    /// was written (`presentMarker`), which launchd's process reads and
    /// takes away; one older than `presentWithin` seconds (a hand-off that
    /// came to nothing), or from the future, says nothing.
    public static func showsWindow(fromAgent: Bool, askedAt: Int?, now: Int) -> Bool {
        guard fromAgent else { return true }
        guard let askedAt else { return false }
        return askedAt <= now && now - askedAt <= presentWithin
    }

    /// How long a hand-off's marker holds: longer than a hand-off takes
    /// (a registration afresh, about 20 seconds at most).
    public static let presentWithin = 60

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
