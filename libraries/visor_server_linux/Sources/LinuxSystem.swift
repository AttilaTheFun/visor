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

    /// Where this program is. /proc/self/exe names the file the process was
    /// started from, and once that file has been replaced (an update put in
    /// its place, or a build copied over it by hand) it says
    /// "<path> (deleted)": the path is still where the program is, the new
    /// build now. A successor started from the name with its suffix never
    /// ran.
    public var executable: String {
        guard let link = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") else { return CommandLine.arguments[0] }
        return Self.program(at: link)
    }

    /// A link's path to a program, without the " (deleted)" Linux adds once
    /// the file it was started from has been replaced.
    static func program(at link: String) -> String {
        let replaced = " (deleted)"
        return link.hasSuffix(replaced) ? String(link.dropLast(replaced.count)) : link
    }

    /// Whether this server runs in a container: said by whoever started it
    /// (`VISOR_IN_CONTAINER=1`, as the Runner starts a container's server),
    /// or by the marker Docker or Podman leave. Apple's container leaves
    /// none, so its servers are told.
    static var inContainer: Bool {
        if let said = ProcessInfo.processInfo.environment["VISOR_IN_CONTAINER"] { return said == "1" }
        return FileManager.default.fileExists(atPath: "/.dockerenv") || FileManager.default.fileExists(atPath: "/run/.containerenv")
    }

    public func platform(log: @escaping @Sendable (String) -> Void, lifecycle: any ServerLifecycle) -> ServerPlatform {
        let data = dataDirectory
        return ServerPlatform(
            listening: POSIXListening(),
            processes: POSIXProcessSignals(),
            secrets: FileSecrets(url: data.appendingPathComponent("secrets.json")),
            fetching: FoundationNetworkingFetching(),
            pushSigning: nil,
            images: HeaderImageMeasuring(),
            files: PollingFileWatching(),
            tools: LinuxTools(),
            host: HostDetails(name: ProcessInfo.processInfo.hostName, system: "linux", inContainer: Self.inContainer, dataDirectory: data,
                              addresses: { POSIXAddresses.all() }, resolve: { POSIXResolver.ipv4($0) }),
            lifecycle: lifecycle,
            agentHosts: POSIXAgentHosting.beside(executable),
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
