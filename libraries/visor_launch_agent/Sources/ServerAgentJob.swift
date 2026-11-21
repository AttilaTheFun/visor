// The server as a background agent on a Mac (docs/DEVELOPMENT.md, The
// server as a background agent): `Visor --server`, Visor.app's own
// executable run headless by this user's launchd, so it has the app's
// signature, keychain items and entitlements, starts at login whether or not
// the app is open, and is started again if it fails. Visor.app is then its
// client. Settled by the app at its launch (ServerHandOver), and only while
// the app's `ServerAsAgent` default is on: off (the default), the server
// runs in the app, as before.
//
// - `<bundle id>.server` (`com.LoganShire.Visor.server`): its plist is the
//   app bundle's own (`Contents/Library/LaunchAgents/<label>.plist`,
//   `BundleProgram` the app's executable), registered with
//   SMAppService.agent (0.65), so nothing of it is written outside the app:
//   unregistering it removes it from launchd and from Background Items
//   alike, and deleting the app takes the plist with it. 0.64 wrote one to
//   ~/Library/LaunchAgents; the app's launch stops and removes it
//   (ServerAgentService).
// - Its log, `Visor-server.log` in Visor's logs (VisorFolders: the Visor
//   volume's `Logs/`, else ~/Library/Logs), is opened by the agent itself
//   as its standard output and error: a plist in the bundle can't name a
//   path in the home folder.
// - KeepAlive after a failure only: an exit of 0 is the server asked to
//   stop (`/api/quit`), or making way for its update, which its watcher
//   starts (ServerAgentRestart). TERM from anyone but launchd's own ending
//   of it is an exit of 1: started again.
// - AbandonProcessGroup: the agents' hosts and the update's watcher are
//   its children, and outlive it.

import Foundation

public enum ServerAgentJob {
    /// The app's argument that makes it the server agent.
    public static let argument = "--server"
    /// The app's default (`defaults write com.LoganShire.Visor
    /// ServerAsAgent -bool true`) that has the server run as the agent.
    public static let defaultsKey = "ServerAsAgent"
    /// The app's command that registers the agent with SMAppService and
    /// ends (`Visor server-agent register`): what the update's watcher runs
    /// when launchd no longer has the job to start again.
    public static let command = "server-agent"

    /// `<bundle id>.server`.
    public static func label(bundleID: String) -> String { bundleID + ".server" }
    /// The plist's name in the bundle's `Contents/Library/LaunchAgents`, as
    /// SMAppService.agent(plistName:) takes it.
    public static func plistName(bundleID: String) -> String { label(bundleID: bundleID) + ".plist" }
    /// Where the plist is in the app bundle.
    public static func bundledPlistPath(bundleID: String, bundle: String) -> String {
        "\(bundle)/Contents/Library/LaunchAgents/\(plistName(bundleID: bundleID))"
    }
    /// The plist 0.64 wrote, `~/Library/LaunchAgents/<label>.plist`: moved
    /// away (stopped and removed) by the app's launch.
    public static func legacyPlistPath(bundleID: String, home: String = NSHomeDirectory()) -> String {
        LaunchAgentJob.plistPath(label: label(bundleID: bundleID), home: home)
    }
    /// `<logs>/Visor-server.log`: Visor's logs' folder (VisorFolders), else
    /// ~/Library/Logs.
    public static func logPath(home: String = NSHomeDirectory(), logs: String? = nil) -> String {
        "\(logs ?? home + "/Library/Logs")/Visor-server.log"
    }

    /// The job by its label and log, as the hand-over and the update's
    /// watcher reach it in launchd: `plistPath` is 0.64's, which only the
    /// migration reads.
    public static func job(bundleID: String, home: String = NSHomeDirectory(), logs: String? = nil) -> LaunchAgentJob {
        LaunchAgentJob(label: label(bundleID: bundleID), argument: argument, name: "the server agent", log: logPath(home: home, logs: logs),
                       abandonsProcessGroup: true, home: home)
    }

    /// The plist the app bundle carries (applications/visor_mac/LaunchAgents,
    /// checked against this by //tests/visor_launch_agent_tests): its
    /// program the bundle's own executable, as SMAppService runs it; no
    /// output paths (the agent opens its log itself) and no version (the
    /// bundle is the version).
    public static func bundledPlist(bundleID: String, executable: String = "Visor") -> [String: Any] {
        [
            "Label": label(bundleID: bundleID),
            "BundleProgram": "Contents/MacOS/\(executable)",
            "ProgramArguments": ["Contents/MacOS/\(executable)", argument],
            "AssociatedBundleIdentifiers": [bundleID],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "ExitTimeOut": 30,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 5,
            "AbandonProcessGroup": true,
        ]
    }

    /// What SMAppService says of the agent (SMAppService.Status's cases).
    public enum ServiceStatus: Equatable, Sendable {
        case notRegistered, enabled, requiresApproval, notFound
    }

    /// What to do, from what is there:
    ///
    /// | wanted | found                                         | this app         | action  |
    /// |--------|-----------------------------------------------|------------------|---------|
    /// | no     | not registered, no 0.64 plist, not running    | any              | nothing |
    /// | no     | registered, a 0.64 plist, or running          | in /Applications | stop    |
    /// | no     | registered, a 0.64 plist, or running          | elsewhere        | refuse  |
    /// | yes    | any                                           | elsewhere        | refuse  |
    /// | yes    | a 0.64 plist                                  | in /Applications | restart |
    /// | yes    | waiting for the person's approval             | in /Applications | hold    |
    /// | yes    | registered and running                        | in /Applications | leave   |
    /// | yes    | registered and not running, or not registered | in /Applications | start   |
    ///
    /// launchd that doesn't answer holds: nothing is stopped or started on
    /// what isn't known.
    public static func decide(wanted: Bool, executable: String?, status: ServiceStatus, legacyPlist: Bool,
                              running: Bool?) -> LaunchAgentJob.Action {
        let there = status == .enabled || status == .requiresApproval || legacyPlist || running == true
        if !wanted, !there, running != nil { return .nothing }
        guard let running else { return .hold("launchd didn't say whether it runs") }
        if let why = LaunchAgentJob.installProblem(executable) { return .refuse(why) }
        guard wanted else { return .stop }
        if legacyPlist { return .restart("0.64's plist in ~/Library/LaunchAgents gives way to the app's own") }
        if status == .requiresApproval {
            return .hold("it waits to be allowed in System Settings › General › Login Items")
        }
        return status == .enabled && running ? .leave : .start
    }
}
