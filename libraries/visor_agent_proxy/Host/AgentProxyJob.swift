// agent-proxy's launchd job on a Mac (as Shireworks' AgentProxyJob, moved
// 19 Nov 2026): Visor itself, `/Applications/Visor.app/Contents/MacOS/Visor
// --agent-proxy` (the app's own executable, so it reads the server's
// keychain items as the app does), a job of this user's launchd, never the
// server's child: a quit, a restart or an update of the app goes on without
// cutting a session's MCP or a container's connections. One of Visor's
// LaunchAgents, settled as each is (LaunchAgentJob):
//
// - Its label is the app's bundle id's, `<bundle id>.agent-proxy`
//   (`com.LoganShire.Visor.agent-proxy`), its plist
//   `~/Library/LaunchAgents/<label>.plist`, its output and errors to
//   `Visor-agent-proxy.log` in Visor's logs (VisorFolders), which it moves aside itself past
//   about 8 MB (LogRotation).
// - The plist carries the app's version and a digest of `agentProxy`
//   (`VISOR_VERSION`, `VISOR_AGENT_PROXY_SETTINGS`). At each start of the
//   server in the app: with settings.json's `agentProxy`, it's written and
//   started (again) when it isn't the same running; without, it's stopped
//   and its plist removed.
// - When the server runs as a background agent (`Visor --server`,
//   ServerAgentJob), agent-proxy runs inside it, as on Linux, and this job
//   is stopped and removed (`folded`).

import Foundation
import VisorLaunchAgent
import VisorServer

public enum AgentProxyJob {
    /// The app's argument that makes it agent-proxy.
    public static let argument = "--agent-proxy"
    /// The plist's EnvironmentVariables entries with the app's version and
    /// the settings' digest.
    public static let versionVariable = LaunchAgentJob.versionVariable
    public static let settingsVariable = "VISOR_AGENT_PROXY_SETTINGS"

    /// `<bundle id>.agent-proxy`.
    public static func label(bundleID: String) -> String { bundleID + ".agent-proxy" }
    /// `~/Library/LaunchAgents/<label>.plist`.
    public static func plistPath(label: String, home: String = NSHomeDirectory()) -> String {
        LaunchAgentJob.plistPath(label: label, home: home)
    }
    /// `<logs>/Visor-agent-proxy.log`: Visor's logs' folder (the Visor
    /// volume's `Logs/` once it's there: VisorFolders), else ~/Library/Logs.
    public static func logPath(home: String = NSHomeDirectory(), logs: String? = nil) -> String {
        "\(logs ?? home + "/Library/Logs")/Visor-agent-proxy.log"
    }
    /// `<logs>/Visor-egress.log`: the egress log's on a Mac.
    public static func egressLogPath(home: String = NSHomeDirectory(), logs: String? = nil) -> String {
        "\(logs ?? home + "/Library/Logs")/Visor-egress.log"
    }

    /// The job for the app with `bundleID`, logging in `logs` (nil: ~/Library/Logs).
    public static func job(bundleID: String, home: String = NSHomeDirectory(), logs: String? = nil) -> LaunchAgentJob {
        LaunchAgentJob(label: label(bundleID: bundleID), argument: argument, name: "agent-proxy", log: logPath(home: home, logs: logs),
                       settingsVariable: settingsVariable, settingsName: "agentProxy", home: home)
    }

    typealias Plist = LaunchAgentJob.Plist
    typealias State = LaunchAgentJob.State
    typealias Action = LaunchAgentJob.Action

    /// Why `executable` can't be the job's program (LaunchAgentJob's).
    static func installProblem(_ executable: String?) -> String? { LaunchAgentJob.installProblem(executable) }

    /// What to do, from what is there (LaunchAgentJob.decide).
    static func decide(_ state: State) -> Action { job(bundleID: "").decide(state) }

    /// The job's plist (LaunchAgentJob.plist).
    static func job(label: String, executable: String, version: String, settings: String, log: String) -> [String: Any] {
        var made = job(bundleID: "")
        made.label = label
        made.log = log
        return made.plist(executable: executable, version: version, settings: settings)
    }

    /// A plist's program, version and settings; nil when it isn't a plist.
    static func plist(from data: Data) -> Plist? { job(bundleID: "").read(data) }
}
