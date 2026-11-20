// The hand-over's steps on a Mac (ServerHandOver): the server's job
// settled with launchctl, and the agent asked on the server's port with
// curl and lsof, as its update's watcher asks (ServerAgentWatch.answers).

#if os(macOS)
import Foundation
import VisorProtocol

public struct LaunchdHandOverSteps: ServerHandOverSteps {
    public let job: LaunchAgentJob
    /// The app's executable, and its version (the plist's).
    public let executable: String?
    public let version: String
    public let port: UInt16
    public let log: @Sendable (String) -> Void

    public init(job: LaunchAgentJob, executable: String? = LaunchAgentJob.ownExecutable, version: String,
                port: UInt16 = Envelope.defaultPort, log: @escaping @Sendable (String) -> Void) {
        self.job = job
        self.executable = executable
        self.version = version
        self.port = port
        self.log = log
    }

    public func installed() async -> Bool {
        if FileManager.default.fileExists(atPath: job.plistPath) { return true }
        return await Launchctl.runningState(label: job.label) == true
    }

    public func install() async -> LaunchAgentJob.Action {
        await job.settle(configured: true, executable: executable, version: version, log: log)
    }

    public func remove() async -> LaunchAgentJob.Action {
        await job.settle(configured: false, executable: executable, version: version, why: "the server runs in the app", log: log)
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
