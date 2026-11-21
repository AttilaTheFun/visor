// agent-proxy as a process of its own: on a Mac, `Visor --agent-proxy`, the
// launchd job the server keeps (AgentProxyJob). It reads settings.json's
// `agentProxy` at its start (the last good it kept when settings.json can't
// be read), starts what's configured, and runs until it's ended (TERM,
// INT). Its own lines go to standard error, which launchd points at
// `Visor-agent-proxy.log` in Visor's logs; past about 8 MB it's moved aside
// (`.1`) and a new one begun (LogRotation).
//
// How it ends says what launchd does next (the job's KeepAlive starts it
// again only after a failure): with nothing configured it exits 0 and stays
// ended, until the server's next start settles the job; with a listener
// that can't be had (the port still another's: Shireworks', before the
// cut-over) it exits 1, and launchd tries again 5 seconds on.

import Foundation
import VisorServer
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

extension AgentProxyHost {
    /// How it was started.
    public struct Launch: Sendable {
        /// Its log lines' prefix.
        public var name: String
        public var places: Places
        public var secrets: any SecretStore
        /// The app's version, for its log.
        public var version: String
        /// The log file standard error is, to move aside past `logLimit`
        /// (LogRotation); nil: none moved.
        public var logFile: String?
        public var logLimit: Int

        public init(name: String = "agent-proxy", places: Places, secrets: any SecretStore, version: String, logFile: String? = nil,
                    logLimit: Int = LogRotation.defaultLimit) {
            self.name = name
            self.places = places
            self.secrets = secrets
            self.version = version
            self.logFile = logFile
            self.logLimit = logLimit
        }
    }

    /// The proxy, run until it's ended (TERM, INT).
    public static func run(_ launch: Launch) -> Never {
        let prefix = launch.name
        // Each line timed, so it reads beside the server's.
        let log: @Sendable (String) -> Void = {
            FileHandle.standardError.write(Data("\(ISO8601DateFormatter().string(from: Date())) \(prefix): \($0)\n".utf8))
        }
        let rotation = launch.logFile.map { LogRotation.watch($0, limit: launch.logLimit, log: log) }
        guard let loaded = loadKeeping(launch.places) else {
            log("\(launch.places.settingsFile.path) has no agentProxy: nothing to do")
            exit(0)
        }
        if loaded.kept { log("\(launch.places.settingsFile.path) can't be read: running with the agentProxy it last started with") }
        guard let running = start(loaded.settings, places: launch.places, secrets: launch.secrets, version: launch.version, log: log),
              running.complete else {
            log("not everything asked for could start: ending, to be started again")
            exit(1)
        }
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let signals = [SIGTERM, SIGINT].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                log("ended by signal \(number): no longer listening")
                running.stop()
                exit(0)
            }
            source.resume()
            return source
        }
        // Held while it runs: dispatchMain never returns.
        withExtendedLifetime((signals, rotation, running)) { dispatchMain() }
    }
}
