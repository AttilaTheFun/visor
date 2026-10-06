import ClaudeTranscript
import Foundation
import VisorServer
import VisorServerCLI
import VisorServerPOSIX

/// The command-line server on Linux: the XDG data directory, a daemon
/// started as a new session, the stop signals, and its own binary replaced
/// by renaming over it.
public struct LinuxSystem: CommandLineSystem {
    public init() {}

    /// $XDG_DATA_HOME/visor, or ~/.local/share/visor ($HOME's, as the XDG
    /// directories are).
    public var dataDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let base = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/share")
        return base.appendingPathComponent("visor")
    }

    public var executable: String {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")) ?? CommandLine.arguments[0]
    }

    public func platform(log: @escaping @Sendable (String) -> Void, lifecycle: any ServerLifecycle) -> ServerPlatform {
        let data = dataDirectory
        return ServerPlatform(
            listening: POSIXListening(),
            terminals: POSIXTerminals(),
            processes: POSIXProcessSignals(),
            secrets: FileSecrets(url: data.appendingPathComponent("secrets.json")),
            fetching: FoundationNetworkingFetching(),
            pushSigning: nil,
            images: HeaderImageMeasuring(),
            files: PollingFileWatching(),
            tools: LinuxTools(),
            host: HostDetails(name: ProcessInfo.processInfo.hostName, dataDirectory: data, addresses: { POSIXAddresses.all() }),
            lifecycle: lifecycle,
            log: log
        )
    }

    public func startDetached(_ executable: String, _ arguments: [String], log: String) throws -> Int32 {
        try POSIXDaemon.start(executable, arguments, log: log)
    }

    @MainActor public func onStop(_ stop: @escaping @Sendable () -> Void) {
        POSIXStopSignals.onStop(stop)
    }

    /// A copy beside it, then renamed over it: the running program keeps
    /// the file it was started from.
    public func install(_ build: String, over executable: String) -> String? {
        let staged = executable + ".new"
        do {
            try? FileManager.default.removeItem(atPath: staged)
            try FileManager.default.copyItem(atPath: build, toPath: staged)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged)
        } catch {
            return "Could not copy \(build): \(error.localizedDescription)"
        }
        guard rename(staged, executable) == 0 else {
            return "Could not put \(build) in place of \(executable): \(String(cString: strerror(errno)))"
        }
        return nil
    }
}
