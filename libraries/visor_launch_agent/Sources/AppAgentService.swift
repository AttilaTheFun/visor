// Visor.app's own agent as SMAppService has it (AppAgentJob): registered
// from the app's own plist, which starts the app (RunAtLoad), or
// unregistered, which takes it out of launchd and Background Items alike.
// Registering afresh is the server agent's (ServerAgentJob.reregister): the
// bundle told to LaunchServices again, unregistered, booted out, then
// registered, as launchd won't start the job from a bundle other than the
// one it was registered from (its launch constraint). Never asked of the
// app's process that launchd runs as the agent: booting the job out ends
// it. What's decided is AppAgentJob's, tested on Linux; this does it, on a
// Mac.

#if os(macOS)
import Foundation
import ServiceManagement

public enum AppAgentService {
    /// The agent's service: the plist in this app's bundle.
    public static func service(bundleID: String) -> SMAppService {
        SMAppService.agent(plistName: AppAgentJob.plistName(bundleID: bundleID))
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

    /// Whether the person wants it (the app's `StartsAtLogin` default, on
    /// unless set off).
    public static var wanted: Bool {
        AppAgentJob.wanted(UserDefaults.standard.object(forKey: AppAgentJob.defaultsKey) as? Bool)
    }

    /// The app started by launchd as the agent, from the bundle in place:
    /// `launchctl kickstart` when it's registered (quick: launchd has it),
    /// and, when that doesn't bring up a process that holds the instance
    /// lock (`started`), registered afresh, which starts it. Whether it
    /// did. `attempts` and `refusedBackoff`: how long a registration may be
    /// tried (the update's watcher waits it out; a person's open of the app
    /// doesn't).
    public static func start(bundleID: String, bundle: String = Bundle.main.bundlePath, attempts: Int = 3,
                             refusedBackoff: [Duration] = ServerAgentJob.refusedBackoff, started: @escaping @Sendable () async -> Bool,
                             log: @escaping @Sendable (String) -> Void) async -> Bool {
        let label = AppAgentJob.label(bundleID: bundleID)
        if status(bundleID: bundleID) == .enabled {
            _ = await Launchctl.run(["kickstart", "\(Launchctl.domain)/\(label)"])
            if await wait(for: started) { return true }
            log("the app's agent was registered, and launchd didn't start it from \(bundle): registered afresh")
        }
        let problem = await ServerAgentJob.reregister(attempts: attempts, refusedBackoff: refusedBackoff,
                                                      refresh: { await ServerAgentService.launchServices(bundle) },
                                                      unregister: { try? await service(bundleID: bundleID).unregister() },
                                                      stop: { await Launchctl.stop(label: label) },
                                                      register: { register(bundleID: bundleID) },
                                                      running: { await Launchctl.pid(label: label) != nil },
                                                      settle: ServerAgentService.registerPause,
                                                      pause: { try? await Task.sleep(for: $0) },
                                                      waiting: { log("the app's agent: \($0)") })
        if let problem {
            log("the app's agent couldn't be registered: \(problem)")
            return false
        }
        if status(bundleID: bundleID) == .requiresApproval {
            log("the app's agent waits to be allowed in System Settings › General › Login Items")
            return false
        }
        return await wait(for: started)
    }

    /// Unregistered, if it is: what went wrong, or nil.
    @discardableResult
    public static func unregister(bundleID: String) async -> String? {
        guard status(bundleID: bundleID) != .notRegistered else { return nil }
        do {
            try await service(bundleID: bundleID).unregister()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Registered: what went wrong, or nil.
    static func register(bundleID: String) -> String? {
        do {
            try service(bundleID: bundleID).register()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Whether `started` says so within AppAgentJob's polls.
    private static func wait(for started: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<AppAgentJob.handPolls {
            if await started() { return true }
            try? await Task.sleep(for: AppAgentJob.handPoll)
        }
        return await started()
    }
}
#endif
