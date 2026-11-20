// One of Visor's LaunchAgents on a Mac: a job of this user's launchd that
// runs Visor.app's own executable with an argument of its own, so it carries
// the app's signature (its keychain items, its entitlements) and is never
// the app's child. Two are settled this way, the same code:
//
// - agent-proxy's, `<bundle id>.agent-proxy`, `Visor --agent-proxy`
//   (AgentProxyJob), while the server runs in the app;
// - the server's, `<bundle id>.server`, `Visor --server` (ServerAgentJob),
//   when the server runs as a background agent (docs/DEVELOPMENT.md, The
//   server as a background agent).
//
// - Its plist is `~/Library/LaunchAgents/<label>.plist` (so launchd starts
//   it at login, before the app), started again after a failure (5 seconds
//   apart), its output and errors to a log of its own.
// - The plist carries the app's version (`VISOR_VERSION`) and, for a job
//   with settings, a digest of them. When it's settled: wanted, and a plist
//   of another version, other settings or another program, or none, or a
//   job that isn't running, and the job is written and started again, once;
//   the same running is left alone. Not wanted, and the job is stopped and
//   its plist removed, so a Mac that never wanted it has none.
// - Written only for an app in /Applications: never for a copy elsewhere
//   (a build to run here, a staging folder, a test run), which logs and
//   leaves the job as it is.
//
// What to do is `decide`'s, from what is found (State), tested on Linux;
// `settle` (LaunchAgentJob+Settle) finds it and does it, on a Mac.

import Foundation

public struct LaunchAgentJob: Sendable, Equatable {
    /// Its launchd label, `<bundle id>.<name>`.
    public var label: String
    /// The app's argument that makes it this job.
    public var argument: String
    /// What its log lines call it ("agent-proxy", "the server agent").
    public var name: String
    /// Its output and errors.
    public var log: String
    /// `~/Library/LaunchAgents/<label>.plist`.
    public var plistPath: String
    /// The plist's EnvironmentVariables entry with a digest of its
    /// settings, and what they're called in what it says; nil: a job with
    /// no settings of its own.
    public var settingsVariable: String?
    public var settingsName: String?
    /// launchd leaves what it started (in its process group) when it ends:
    /// the server's agents' hosts and its update's watcher outlive it.
    public var abandonsProcessGroup: Bool

    public init(label: String, argument: String, name: String, log: String, settingsVariable: String? = nil, settingsName: String? = nil,
                abandonsProcessGroup: Bool = false, home: String = NSHomeDirectory()) {
        self.label = label
        self.argument = argument
        self.name = name
        self.log = log
        plistPath = Self.plistPath(label: label, home: home)
        self.settingsVariable = settingsVariable
        self.settingsName = settingsName
        self.abandonsProcessGroup = abandonsProcessGroup
    }

    /// The plist's EnvironmentVariables entry with the app's version.
    public static let versionVariable = "VISOR_VERSION"
    /// Where an app may run a job from.
    public static let installedFolder = "/Applications/"

    /// `~/Library/LaunchAgents/<label>.plist`.
    public static func plistPath(label: String, home: String = NSHomeDirectory()) -> String { "\(home)/Library/LaunchAgents/\(label).plist" }

    /// What a plist found says.
    public struct Plist: Equatable, Sendable {
        public var program: [String]
        public var version: String?
        public var settings: String?

        public init(program: [String], version: String?, settings: String?) {
            self.program = program
            self.version = version
            self.settings = settings
        }
    }

    /// What `settle` finds.
    public struct State: Equatable, Sendable {
        /// The job is wanted (agent-proxy: settings.json has `agentProxy`;
        /// the server: it runs as an agent); nil when that can't be read
        /// (a settings error never tears down what runs).
        public var configured: Bool?
        /// This process's executable, its links resolved (nil: unknown).
        public var executable: String?
        /// The app's version.
        public var version: String
        /// The digest of its settings now; nil for a job with none.
        public var settings: String?
        /// The plist there now, if any.
        public var plist: Plist?
        /// launchd has the job and it hasn't ended; nil when launchd
        /// couldn't say.
        public var running: Bool?

        public init(configured: Bool?, executable: String?, version: String, settings: String?, plist: Plist?, running: Bool?) {
            self.configured = configured
            self.executable = executable
            self.version = version
            self.settings = settings
            self.plist = plist
            self.running = running
        }
    }

    public enum Action: Equatable, Sendable {
        /// Nothing there, nothing asked.
        case nothing
        /// Written and started: there was no job running.
        case start
        /// Written and started again: a job ran with another plist (`why`).
        case restart(String)
        /// The same running: left alone.
        case leave
        /// Stopped and its plist removed: not wanted.
        case stop
        /// This copy of the app may not write the job (`why`): left as it is.
        case refuse(String)
        /// Not known what to do: left as it is, said why.
        case hold(String)
    }

    /// Why `executable` can't be a job's program: it must be an app's own
    /// executable (`<app>.app/Contents/MacOS/<name>`) in /Applications. Nil
    /// when it may.
    public static func installProblem(_ executable: String?) -> String? {
        guard let executable else { return "this process's executable isn't known" }
        let parts = executable.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard executable.hasPrefix(installedFolder), parts.count == 6, parts[2].hasSuffix(".app"), parts[3] == "Contents",
              parts[4] == "MacOS", !parts[5].isEmpty else {
            return "\(executable) isn't the own executable of an app in /Applications (a build to run here, a copy, a test run)"
        }
        return nil
    }

    /// The job's ProgramArguments for `executable`.
    public func program(_ executable: String) -> [String] { [executable, argument] }

    /// What to do, from what is there:
    ///
    /// | wanted | plist / job                                 | this app         | action  |
    /// |--------|---------------------------------------------|------------------|---------|
    /// | no     | no plist, not running                       | any              | nothing |
    /// | no     | a plist, or running                         | in /Applications | stop    |
    /// | no     | a plist, or running                         | elsewhere        | refuse  |
    /// | yes    | any                                         | elsewhere        | refuse  |
    /// | yes    | not running                                 | in /Applications | start   |
    /// | yes    | running, no plist                           | in /Applications | restart |
    /// | yes    | running, another version, settings, program | in /Applications | restart |
    /// | yes    | running, this version, settings and program | in /Applications | leave   |
    ///
    /// Settings that can't be read, or launchd that doesn't answer, holds:
    /// nothing is stopped or restarted on what isn't known.
    public func decide(_ state: State) -> Action {
        if state.configured == nil, state.plist == nil, state.running == false { return .nothing }
        guard let configured = state.configured else { return .hold("settings.json can't be read") }
        guard let running = state.running else { return .hold("launchd didn't say whether it runs") }
        if !configured, state.plist == nil, !running { return .nothing }
        if let why = Self.installProblem(state.executable) { return .refuse(why) }
        guard configured else { return .stop }
        guard running else { return .start }
        guard let plist = state.plist else { return .restart("running without its plist") }
        if plist.version != state.version { return .restart("its plist is \(plist.version ?? "of no version"), this is \(state.version)") }
        if plist.settings != state.settings { return .restart("\(settingsName ?? "its settings") changed") }
        if plist.program != program(state.executable ?? "") { return .restart("its plist runs \(plist.program.joined(separator: " "))") }
        return .leave
    }

    /// The job's plist: RunAtLoad; Interactive (not throttled as a
    /// background job is); 30 seconds to end; its output and errors to its
    /// log; started again after a failure (not after an exit of 0: it was
    /// asked to end, or has nothing to do), 5 seconds apart at least.
    public func plist(executable: String, version: String, settings: String?) -> [String: Any] {
        var environment = [Self.versionVariable: version]
        if let settingsVariable, let settings { environment[settingsVariable] = settings }
        var job: [String: Any] = [
            "Label": label,
            "ProgramArguments": program(executable),
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "ExitTimeOut": 30,
            "StandardOutPath": log,
            "StandardErrorPath": log,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 5,
            "EnvironmentVariables": environment,
        ]
        if abandonsProcessGroup { job["AbandonProcessGroup"] = true }
        return job
    }

    /// The plist's bytes, as written.
    public func plistData(executable: String, version: String, settings: String?) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist(executable: executable, version: version, settings: settings),
                                           format: .xml, options: 0)
    }

    /// A plist's program, version and settings; nil when it isn't a plist.
    public func read(_ data: Data) -> Plist? {
        guard let job = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        let environment = job["EnvironmentVariables"] as? [String: Any]
        return Plist(program: job["ProgramArguments"] as? [String] ?? [], version: environment?[Self.versionVariable] as? String,
                     settings: settingsVariable.flatMap { environment?[$0] as? String })
    }

    /// The process id in what `launchctl print` says of a running job
    /// (`pid = 123`); nil when it says none.
    public static func pid(inPrint output: String) -> Int32? {
        for line in output.split(separator: "\n") {
            let words = line.split(whereSeparator: \.isWhitespace)
            if words.count == 3, words[0] == "pid", words[1] == "=", let pid = Int32(words[2]), pid > 0 { return pid }
        }
        return nil
    }
}
