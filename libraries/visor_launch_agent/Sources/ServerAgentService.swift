// The server's agent as SMAppService has it (ServerAgentJob): registered
// from the app's own plist, started, or stopped and unregistered (which
// takes it out of Background Items too), with 0.64's plist in
// ~/Library/LaunchAgents stopped and removed on the way. What to do is
// ServerAgentJob.decide's, tested on Linux; this does it, on a Mac.

#if os(macOS)
import Foundation
import ServiceManagement

public enum ServerAgentService {
    /// The agent's service: the plist in this app's bundle.
    public static func service(bundleID: String) -> SMAppService {
        SMAppService.agent(plistName: ServerAgentJob.plistName(bundleID: bundleID))
    }

    /// What SMAppService says of it.
    public static func status(bundleID: String) -> ServerAgentJob.ServiceStatus {
        switch service(bundleID: bundleID).status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        default: .notRegistered
        }
    }

    /// Whether the agent is there: registered (or waiting for approval),
    /// 0.64's plist, or launchd has it running.
    public static func installed(bundleID: String) async -> Bool {
        if isRegisteredOrLegacy(bundleID: bundleID) { return true }
        return await Launchctl.runningState(label: ServerAgentJob.label(bundleID: bundleID)) == true
    }

    /// Whether it's registered (or waiting for approval), or 0.64's plist is
    /// there: asked without launchd, at the app's launch.
    public static func isRegisteredOrLegacy(bundleID: String) -> Bool {
        let status = status(bundleID: bundleID)
        return status == .enabled || status == .requiresApproval
            || FileManager.default.fileExists(atPath: ServerAgentJob.legacyPlistPath(bundleID: bundleID))
    }

    /// Registered, from this app (`Visor server-agent register`): what went
    /// wrong, or nil.
    public static func register(bundleID: String) -> String? {
        do {
            try service(bundleID: bundleID).register()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Registered afresh (ServerAgentJob.reregister): the bundle told to
    /// LaunchServices again, unregistered, out of launchd, then registered,
    /// which starts it from the bundle in place now, its launch constraint
    /// that bundle's; again while launchd has no process of it. What `Visor server-agent register` runs (the update's
    /// watcher, after an update or a rollback), and how the hand-over starts
    /// one that isn't running.
    public static func reregister(bundleID: String, bundle: String = Bundle.main.bundlePath,
                                  waiting: (String) -> Void = { _ in }) async -> String? {
        let label = ServerAgentJob.label(bundleID: bundleID)
        return await ServerAgentJob.reregister(refresh: { await launchServices(bundle) },
                                               unregister: { try? await service(bundleID: bundleID).unregister() },
                                               stop: { await Launchctl.stop(label: label) },
                                               register: { register(bundleID: bundleID) },
                                               running: { await Launchctl.pid(label: label) != nil },
                                               settle: registerPause,
                                               pause: { try? await Task.sleep(for: $0) },
                                               waiting: waiting)
    }

    /// How long a registration is given before launchd is asked whether it
    /// runs: long enough, when it was refused for its launch constraint,
    /// for Background Items to have dropped its record of the job (about
    /// five seconds after the refusal, on macOS 27.0.1), so the next
    /// registration makes a new one of the build in place.
    static let registerPause: Duration = .seconds(8)

    /// LaunchServices' own tool, which Background Items reads the app's
    /// record from.
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// The bundle registered with LaunchServices again (`lsregister -f`), as
    /// it is now.
    static func launchServices(_ bundle: String) async {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: lsregister)
            process.arguments = ["-f", bundle]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
        }.value
    }

    /// 0.64's plist: its job stopped and the file removed, if it's there.
    /// Whether there was one.
    @discardableResult
    public static func removeLegacy(job: LaunchAgentJob, bundleID: String, log: @Sendable (String) -> Void) async -> Bool {
        let path = ServerAgentJob.legacyPlistPath(bundleID: bundleID)
        guard FileManager.default.fileExists(atPath: path) else { return false }
        await Launchctl.stop(label: job.label)
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + ".previous")
        log("\(job.name): 0.64's \(path) stopped and removed: the app's own plist takes over")
        return true
    }

    /// Settled as ServerAgentJob.decide says: registered and started (or
    /// left), or stopped and unregistered. What was done.
    @discardableResult
    public static func settle(wanted: Bool, job: LaunchAgentJob, bundleID: String, executable: String?, why unwanted: String = "not wanted",
                              notice: @escaping @Sendable (String) -> Void = { _ in },
                              log: @escaping @Sendable (String) -> Void) async -> LaunchAgentJob.Action {
        let legacy = FileManager.default.fileExists(atPath: ServerAgentJob.legacyPlistPath(bundleID: bundleID))
        let running = await Launchctl.runningState(label: job.label)
        let action = ServerAgentJob.decide(wanted: wanted, executable: executable, status: status(bundleID: bundleID),
                                           legacyPlist: legacy, running: running)
        switch action {
        case .nothing:
            break
        case .leave:
            log("\(job.name): registered and running: left running")
        case .refuse(let why), .hold(let why):
            log("\(job.name): \(why): left as it is")
        case .stop:
            await removeLegacy(job: job, bundleID: bundleID, log: log)
            // Not registered (0.64's plist alone): nothing to undo there.
            try? await service(bundleID: bundleID).unregister()
            await Launchctl.stop(label: job.label)
            log("\(job.name): \(unwanted): stopped and unregistered")
        case .start, .restart:
            await removeLegacy(job: job, bundleID: bundleID, log: log)
            // Not running: booted out and registered again, whatever bundle
            // it was registered from.
            if let problem = await reregister(bundleID: bundleID, waiting: { log("\(job.name): " + $0); notice($0) }) {
                log("\(job.name): couldn't be registered: \(problem)")
                return .hold(problem)
            }
            if status(bundleID: bundleID) == .requiresApproval {
                let why = "it waits to be allowed in System Settings › General › Login Items"
                log("\(job.name): registered; \(why)")
                return .hold(why)
            }
            log("\(job.name): registered and started from the app's own plist (\(executable ?? "?") \(job.argument)); its log \(job.log)")
        }
        return action
    }
}
#endif
