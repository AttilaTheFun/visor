// agent-proxy's launchd job on a Mac (as Shireworks' AgentProxyJob, moved
// 19 Nov 2026): Visor itself, `/Applications/Visor.app/Contents/MacOS/Visor
// --agent-proxy` (the app's own executable, so it reads the server's
// keychain items as the app does), a job of this user's launchd, never the
// server's child: a quit, a restart or an update of the app goes on without
// cutting a session's MCP or a container's connections.
//
// - Its label is the app's bundle id's, `<bundle id>.agent-proxy`
//   (`com.LoganShire.Visor.agent-proxy`), its plist
//   `~/Library/LaunchAgents/<label>.plist` (so launchd starts it at login,
//   before the app), KeepAlive after a failure (5 seconds apart), its output
//   and errors to `~/Library/Logs/Visor-agent-proxy.log`, which it moves
//   aside itself past about 8 MB (LogRotation).
// - The plist carries the app's version and a digest of `agentProxy`
//   (`VISOR_VERSION`, `VISOR_AGENT_PROXY_SETTINGS`). At each start of the
//   server: with settings.json's `agentProxy`, a plist of another version,
//   other settings or another program, or none, or a job that isn't
//   running, and the job is written and started again, once; the same
//   running is left alone, so a restart of the server cuts nothing. Without
//   `agentProxy` the job is stopped and its plist removed, so a Mac that
//   never set it has none.
// - Written only for an app in /Applications: never for a copy elsewhere
//   (a build to run here, a staging folder, a test run), which logs and
//   leaves the job as it is.
//
// What to do is `decide`'s, from what is found (State), tested on Linux;
// `settle` finds it and does it, on a Mac.

import Foundation
import VisorServer

public enum AgentProxyJob {
    /// The app's argument that makes it agent-proxy.
    public static let argument = "--agent-proxy"
    /// The plist's EnvironmentVariables entries with the app's version and
    /// the settings' digest.
    public static let versionVariable = "VISOR_VERSION"
    public static let settingsVariable = "VISOR_AGENT_PROXY_SETTINGS"
    /// Where an app may run the job from.
    public static let installedFolder = "/Applications/"

    /// `<bundle id>.agent-proxy`.
    public static func label(bundleID: String) -> String { bundleID + ".agent-proxy" }
    /// `~/Library/LaunchAgents/<label>.plist`.
    public static func plistPath(label: String, home: String = NSHomeDirectory()) -> String { "\(home)/Library/LaunchAgents/\(label).plist" }
    /// `~/Library/Logs/Visor-agent-proxy.log`.
    public static func logPath(home: String = NSHomeDirectory()) -> String { "\(home)/Library/Logs/Visor-agent-proxy.log" }
    /// `~/Library/Logs/Visor-egress.log`: the egress log's on a Mac.
    public static func egressLogPath(home: String = NSHomeDirectory()) -> String { "\(home)/Library/Logs/Visor-egress.log" }

    /// What a plist found says.
    struct Plist: Equatable {
        var program: [String]
        var version: String?
        var settings: String?
    }

    /// What `settle` finds.
    struct State: Equatable {
        /// settings.json has `agentProxy`; nil when it can't be read (a
        /// settings error never tears down what runs).
        var configured: Bool?
        /// This process's executable, its links resolved (nil: unknown).
        var executable: String?
        /// The app's version.
        var version: String
        /// The digest of `agentProxy` now.
        var settings: String
        /// The plist there now, if any.
        var plist: Plist?
        /// launchd has the job and it hasn't ended; nil when launchd
        /// couldn't say.
        var running: Bool?
    }

    enum Action: Equatable {
        /// Nothing there, nothing asked.
        case nothing
        /// Written and started: there was no job running.
        case start
        /// Written and started again: a job ran with another plist (`why`).
        case restart(String)
        /// The same running: left alone.
        case leave
        /// Stopped and its plist removed: no `agentProxy`.
        case stop
        /// This copy of the app may not write the job (`why`): left as it is.
        case refuse(String)
        /// Not known what to do: left as it is, said why.
        case hold(String)
    }

    /// Why `executable` can't be the job's program: it must be an app's own
    /// executable (`<app>.app/Contents/MacOS/<name>`) in /Applications. Nil
    /// when it may.
    static func installProblem(_ executable: String?) -> String? {
        guard let executable else { return "this process's executable isn't known" }
        let parts = executable.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard executable.hasPrefix(installedFolder), parts.count == 6, parts[2].hasSuffix(".app"), parts[3] == "Contents",
              parts[4] == "MacOS", !parts[5].isEmpty else {
            return "\(executable) isn't the own executable of an app in /Applications (a build to run here, a copy, a test run)"
        }
        return nil
    }

    /// The job's ProgramArguments for `executable`.
    static func program(_ executable: String) -> [String] { [executable, argument] }

    /// What to do, from what is there:
    ///
    /// | agentProxy | plist / job                                 | this app         | action  |
    /// |------------|---------------------------------------------|------------------|---------|
    /// | no         | no plist, not running                       | any              | nothing |
    /// | no         | a plist, or running                         | in /Applications | stop    |
    /// | no         | a plist, or running                         | elsewhere        | refuse  |
    /// | yes        | any                                         | elsewhere        | refuse  |
    /// | yes        | not running                                 | in /Applications | start   |
    /// | yes        | running, no plist                           | in /Applications | restart |
    /// | yes        | running, another version, settings, program | in /Applications | restart |
    /// | yes        | running, this version, settings and program | in /Applications | leave   |
    ///
    /// settings.json that can't be read, or launchd that doesn't answer,
    /// holds: nothing is stopped or restarted on what isn't known.
    static func decide(_ state: State) -> Action {
        if state.configured == nil, state.plist == nil, state.running == false { return .nothing }
        guard let configured = state.configured else { return .hold("settings.json can't be read") }
        guard let running = state.running else { return .hold("launchd didn't say whether it runs") }
        if !configured, state.plist == nil, !running { return .nothing }
        if let why = installProblem(state.executable) { return .refuse(why) }
        guard configured else { return .stop }
        guard running else { return .start }
        guard let plist = state.plist else { return .restart("running without its plist") }
        if plist.version != state.version { return .restart("its plist is \(plist.version ?? "of no version"), this is \(state.version)") }
        if plist.settings != state.settings { return .restart("agentProxy changed") }
        if plist.program != program(state.executable ?? "") { return .restart("its plist runs \(plist.program.joined(separator: " "))") }
        return .leave
    }

    /// The job's plist: RunAtLoad; Interactive (not throttled as a
    /// background job is); 30 seconds to end; its output and errors to
    /// `log`; started again after a failure (not after an exit of 0: nothing
    /// to do), 5 seconds apart at least.
    static func job(label: String, executable: String, version: String, settings: String, log: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": program(executable),
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "ExitTimeOut": 30,
            "StandardOutPath": log,
            "StandardErrorPath": log,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 5,
            "EnvironmentVariables": [versionVariable: version, settingsVariable: settings],
        ]
    }

    /// A plist's program, version and settings; nil when it isn't a plist.
    static func plist(from data: Data) -> Plist? {
        guard let job = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        let environment = job["EnvironmentVariables"] as? [String: Any]
        return Plist(program: job["ProgramArguments"] as? [String] ?? [], version: environment?[versionVariable] as? String,
                     settings: environment?[settingsVariable] as? String)
    }
}
