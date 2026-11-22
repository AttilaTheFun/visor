// The hand-over's steps on a Mac (ServerHandOver): the server's agent
// registered and unregistered with SMAppService (its plist the app
// bundle's: ServerAgentJob, ServerAgentService), 0.64's plist in
// ~/Library/LaunchAgents stopped and removed first, and the agent asked on
// the server's port with curl and lsof, as its update's watcher asks
// (ServerAgentWatch.answers).

#if os(macOS)
import Foundation
import VisorProtocol

public struct LaunchdHandOverSteps: ServerHandOverSteps {
    public let job: LaunchAgentJob
    public let bundleID: String
    /// The app's executable.
    public let executable: String?
    public let port: UInt16
    /// Told what the person should see while registering waits on macOS
    /// ("Waiting for macOS to let Visor's server start…").
    public let notice: @Sendable (String) -> Void
    public let log: @Sendable (String) -> Void

    public init(job: LaunchAgentJob, bundleID: String, executable: String? = LaunchAgentJob.ownExecutable,
                port: UInt16 = Envelope.defaultPort, notice: @escaping @Sendable (String) -> Void = { _ in },
                log: @escaping @Sendable (String) -> Void) {
        self.job = job
        self.bundleID = bundleID
        self.executable = executable
        self.port = port
        self.notice = notice
        self.log = log
    }

    public func installed() async -> Bool {
        await ServerAgentService.installed(bundleID: bundleID)
    }

    public func install() async -> LaunchAgentJob.Action {
        await ServerAgentService.settle(wanted: true, job: job, bundleID: bundleID, executable: executable, notice: notice, log: log)
    }

    public func remove() async -> LaunchAgentJob.Action {
        await ServerAgentService.settle(wanted: false, job: job, bundleID: bundleID, executable: executable,
                                        why: "the server runs in the app", log: log)
    }

    public func agentPID() async -> Int32? {
        await Launchctl.pid(label: job.label)
    }

    public func answers(_ pid: Int32) async -> Bool {
        let check = ServerAgentWatch.answers(port: port)
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", check]
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "p": String(pid)]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }

    public func pause(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}
#endif
