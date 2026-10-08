import ClaudeTranscript
import Foundation
import VisorServer
import VisorServerApple
import VisorServerCLI
import VisorServerPOSIX
import VisorServerSSH

/// The command-line server on a Mac, without the menu bar app: its data
/// in ~/Library/Application Support/visor-server (or VISOR_DATA_DIR, for a
/// sandbox that gives it a folder), secrets in a file there rather than
/// the keychain (nothing to ask a user who is not there), POSIX sockets,
/// terminals and signals, and the Mac's own fetching, push signing,
/// images, file watching and tools.
public struct MacSystem: CommandLineSystem {
    public init() {}

    public var dataDirectory: URL {
        if let given = ProcessInfo.processInfo.environment["VISOR_DATA_DIR"], !given.isEmpty {
            return URL(fileURLWithPath: given, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("visor-server", isDirectory: true)
    }

    public var executable: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    public func platform(log: @escaping @Sendable (String) -> Void, lifecycle: any ServerLifecycle) -> ServerPlatform {
        let data = dataDirectory
        return ServerPlatform(
            listening: POSIXListening(),
            terminals: POSIXTerminals(),
            processes: POSIXProcessSignals(),
            secrets: FileSecrets(url: data.appendingPathComponent("secrets.json")),
            fetching: URLSessionFetching(),
            pushSigning: CryptoKitPushSigning(),
            images: ImageIOMeasuring(),
            files: DispatchFileWatching(),
            tools: MacTools(),
            host: HostDetails(name: Host.current().localizedName ?? ProcessInfo.processInfo.hostName, dataDirectory: data,
                              addresses: { NetworkAddresses.all().map(\.address) },
                              networkAddresses: { NetworkAddresses.all().map { NetworkAddress(address: $0.address, interface: $0.name) } }),
            lifecycle: lifecycle,
            log: log,
            ssh: ConnectorPeerSSH()
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
