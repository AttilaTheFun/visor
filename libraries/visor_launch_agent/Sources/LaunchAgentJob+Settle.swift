// A job made to match what's wanted and this app, as `decide` says, on a
// Mac. launchctl is asked off the main thread.

#if os(macOS)
import Darwin
import Foundation

extension LaunchAgentJob {
    /// This process's executable, its links resolved.
    public static var ownExecutable: String? { Bundle.main.executableURL?.resolvingSymlinksInPath().path }

    /// What's there now: the plist and whether launchd runs it.
    public func state(configured: Bool?, executable: String?, version: String, settings: String?) async -> State {
        let found = FileManager.default.contents(atPath: plistPath)
        return State(configured: configured, executable: executable, version: version, settings: settings,
                     plist: found.map { read($0) ?? Plist(program: [], version: nil, settings: nil) },
                     running: await Launchctl.runningState(label: label))
    }

    /// The job settled: written and started, left, or stopped and removed,
    /// as `decide` says. What was done.
    @discardableResult
    public func settle(configured: Bool?, executable: String? = LaunchAgentJob.ownExecutable, version: String, settings: String? = nil,
                       why unwanted: String = "not wanted", log: @escaping @Sendable (String) -> Void) async -> Action {
        let state = await state(configured: configured, executable: executable, version: version, settings: settings)
        let action = decide(state)
        switch action {
        case .nothing:
            break
        case .leave:
            log("\(name): its launchd job runs \(state.version): left running")
        case .refuse(let why), .hold(let why):
            log("\(name): \(why): its launchd job (\(label)) left as it is")
        case .stop:
            await Launchctl.stop(label: label)
            try? FileManager.default.removeItem(atPath: plistPath)
            log("\(name): \(unwanted): its launchd job stopped and \(plistPath) removed")
        case .start, .restart:
            guard let executable = state.executable else { return .hold("this process's executable isn't known") }
            let why: String
            if case .restart(let said) = action { why = "started again (\(said))" } else { why = "started" }
            do {
                try write(executable: executable, version: state.version, settings: state.settings)
                await Launchctl.stop(label: label)
                if let problem = await Launchctl.bootstrap(plist: plistPath) {
                    log("\(name): its launchd job couldn't be started: \(problem)")
                    return .hold(problem)
                }
                log("\(name): its launchd job \(why): \(executable) \(argument), \(state.version); its log \(self.log)")
            } catch {
                log("\(name): its launchd job couldn't be written: \(error)")
                return .hold("\(error)")
            }
        }
        return action
    }

    /// Its plist written (and its folder, and its log, its owner's alone
    /// before launchd opens it: launchd would make it with the default
    /// mode). Not loaded: `settle` or the caller does that.
    public func write(executable: String, version: String, settings: String?) throws {
        try FileManager.default.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: (log as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let file = open(log, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if file >= 0 { _ = fchmod(file, 0o600); close(file) }
        try plistData(executable: executable, version: version, settings: settings).write(to: URL(fileURLWithPath: plistPath), options: .atomic)
    }
}
#endif
