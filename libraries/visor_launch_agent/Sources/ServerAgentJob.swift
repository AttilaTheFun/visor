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
    /// | yes    | running (whatever SMAppService says)          | in /Applications | leave   |
    /// | yes    | waiting for the person's approval             | in /Applications | hold    |
    /// | yes    | registered and not running, or not registered | in /Applications | start   |
    ///
    /// launchd that doesn't answer holds: nothing is stopped or started on
    /// what isn't known. Wanted, a running agent is never stopped (NCH's
    /// check of #491: a reopen that read its status wrong ended it, and the
    /// app served in its place); only 0.64's job is, once, to give way.
    public static func decide(wanted: Bool, executable: String?, status: ServiceStatus, legacyPlist: Bool,
                              running: Bool?) -> LaunchAgentJob.Action {
        let there = status == .enabled || status == .requiresApproval || legacyPlist || running == true
        if !wanted, !there, running != nil { return .nothing }
        guard let running else { return .hold("launchd didn't say whether it runs") }
        if let why = LaunchAgentJob.installProblem(executable) { return .refuse(why) }
        guard wanted else { return .stop }
        if legacyPlist { return .restart("0.64's plist in ~/Library/LaunchAgents gives way to the app's own") }
        if running { return .leave }
        if status == .requiresApproval {
            return .hold("it waits to be allowed in System Settings › General › Login Items")
        }
        return .start
    }

    /// The agent registered afresh: the bundle in place told to
    /// LaunchServices again (`refresh`: `lsregister -f`), unregistered
    /// (`unregister`: SMAppService's), out of launchd (`stop`: launchctl
    /// bootout, waited for), then registered (`register`: SMAppService,
    /// which starts it), and, if launchd hasn't it running a moment later
    /// (`running`, after `pause`), all of it again, up to `attempts` times;
    /// what went wrong, or nil. The one way it's started once its bundle
    /// may have changed (ServerAgentService.reregister): an update to
    /// another build, a rollback to the one before, a start of a registered
    /// job that isn't running.
    ///
    /// Background Items keeps a record of the job with its executable's
    /// checksum as the job's launch constraint, and launchd won't spawn it
    /// from another build put in its place (`spawn failed`, "Launch
    /// Constraint Violation", exit 78, "needs LWCR update": NCH's check of
    /// #491). On macOS 27.0.1, between two ad hoc builds, the first
    /// registration after the bundle changed was refused so, whatever came
    /// before it (a bootout, an unregister, `lsregister -f`); about five
    /// seconds on, Background Items dropped its record of the job, and the
    /// next registration made a new one and ran the new build. So it's
    /// tried again, once the record has had time to go, rather than left
    /// down.
    ///
    /// Registering can also be refused for a while ("Operation not
    /// permitted": NCH's check of #491): just after 0.64's plist is removed,
    /// Background Items still holds 0.64's item of the same identifier, and
    /// smd says the job "is not allowed to bootstrap" until a later rescan
    /// drops it. That's waited out (`waiting` told why), the registration
    /// tried again after `refusedBackoff`'s pauses (about a minute and a
    /// half), and only then given up, saying so.
    public static func reregister(attempts: Int = 3, refusedBackoff: [Duration] = refusedBackoff, refresh: () async -> Void,
                                  unregister: () async -> Void, stop: () async -> Void, register: () async -> String?,
                                  running: () async -> Bool, settle: Duration = .seconds(8), pause: (Duration) async -> Void,
                                  waiting: (String) -> Void = { _ in }) async -> String? {
        var refusals = refusedBackoff[...]
        var attempt = 0
        while attempt < max(attempts, 1) {
            await refresh()
            await unregister()
            await stop()
            if let problem = await register() {
                guard isRefusedForNow(problem) else { return problem }
                guard let next = refusals.popFirst() else {
                    return "macOS didn't let Visor's server start for about \(refusedBackoff.reduce(0) { $0 + $1.components.seconds }) seconds "
                        + "(\(problem)): open Visor again, or allow it in System Settings › General › Login Items"
                }
                waiting("Waiting for macOS to let Visor's server start… (\(problem))")
                await pause(next)
                continue
            }
            attempt += 1
            await pause(settle)
            if await running() { return nil }
        }
        return "launchd didn't start it after \(max(attempts, 1)) registrations (its launch constraint: the build registered isn't the one in place)"
    }

    /// The pauses between registrations macOS refuses for now: about a
    /// minute and a half in all.
    public static let refusedBackoff: [Duration] = [.seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(15), .seconds(15),
                                                     .seconds(15), .seconds(15)]

    /// Whether a registration's refusal is macOS not allowing it yet (EPERM,
    /// "not permitted", "not allowed"), which passes, rather than a refusal
    /// for good.
    public static func isRefusedForNow(_ problem: String) -> Bool {
        let said = problem.lowercased()
        return said.contains("not permitted") || said.contains("not allowed") || said.contains("eperm")
    }
}
