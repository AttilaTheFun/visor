// The hand-back's steps on a Mac (ServerHandBack): the server agent
// unregistered with SMAppService and booted out of launchd (its plist the
// app bundle's: ServerAgentJob, ServerAgentService), 0.64's plist in
// ~/Library/LaunchAgents stopped and removed with it; the socket files and
// the port asked whether a server still answers; an update's watch read
// from its lock (RelaunchWatchLock); and `/api/quit` asked by the app's own
// client, as a last resort.

#if os(macOS)
import Darwin
import Foundation
import VisorProtocol
import VisorServer
import VisorServerPOSIX

public struct LaunchdHandBackSteps: ServerHandBackSteps {
    public let job: LaunchAgentJob
    public let bundleID: String
    /// The app's executable.
    public let executable: String?
    /// The socket files a server answers at (the one in use and 0.64's).
    public let sockets: [String]
    /// The update watch's lock file (RelaunchWatchLock.url).
    public let lock: String
    public let port: UInt16
    /// `/api/quit`, as the app's client: what went wrong, or nil.
    public let askToQuit: @Sendable () async -> String?
    public let log: @Sendable (String) -> Void

    public init(job: LaunchAgentJob, bundleID: String, executable: String? = LaunchAgentJob.ownExecutable, sockets: [String], lock: String,
                port: UInt16 = Envelope.defaultPort, askToQuit: @escaping @Sendable () async -> String?,
                log: @escaping @Sendable (String) -> Void) {
        self.job = job
        self.bundleID = bundleID
        self.executable = executable
        self.sockets = sockets
        self.lock = lock
        self.port = port
        self.askToQuit = askToQuit
        self.log = log
    }

    public func agentThere() async -> Bool {
        await ServerAgentService.installed(bundleID: bundleID)
    }

    public func watching() async -> Int? {
        // Its holder must be the watcher that took it, not a process that
        // reused its pid since (RelaunchWatchHolder).
        let text = try? String(contentsOfFile: lock, encoding: .utf8)
        return RelaunchWatchHolder.remaining(text, now: Int(Date().timeIntervalSince1970))
    }

    public func remove() async -> LaunchAgentJob.Action {
        await ServerAgentService.settle(wanted: false, job: job, bundleID: bundleID, executable: executable,
                                        why: "the server runs in the app (0.72.1)", log: log)
    }

    public func serverAnswers() async -> Bool {
        let sockets = sockets
        let port = port
        return await Task.detached {
            sockets.contains { POSIXUnixSocket.answers($0) } || Self.portAnswers(port)
        }.value
    }

    public func quit() async -> String? {
        await askToQuit()
    }

    public func pause(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }

    /// Whether something listens on 127.0.0.1:`port`.
    public static func portAnswers(_ port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return connected == 0
    }
}
#endif
