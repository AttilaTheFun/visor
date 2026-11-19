// The job made to match settings.json and this app, as `decide` says: at
// the server's start, on a Mac (Visor's own, VisorMacApp). launchctl is
// asked off the main thread.

#if os(macOS)
import Darwin
import Foundation
import VisorServer

extension AgentProxyJob {
    /// The job settled for the app this process is, its data in `places`.
    public static func settle(bundleID: String, version: String, places: AgentProxyHost.Places,
                              log: @escaping @Sendable (String) -> Void) async {
        let label = label(bundleID: bundleID)
        let plistPath = plistPath(label: label)
        let logPath = logPath()
        let configured: Bool?
        let settings: AgentProxySettings?
        do {
            settings = try AgentProxyHost.configured(at: places.settingsFile)
            configured = settings != nil
        } catch {
            settings = nil
            configured = nil
        }
        let found = FileManager.default.contents(atPath: plistPath)
        let state = State(configured: configured, executable: Bundle.main.executableURL?.resolvingSymlinksInPath().path,
                          version: version, settings: AgentProxyHost.digest(settings),
                          plist: found.map { plist(from: $0) ?? Plist(program: [], version: nil, settings: nil) },
                          running: await Launchctl.runningState(label: label))
        let action = decide(state)
        switch action {
        case .nothing:
            return
        case .leave:
            log("agent-proxy: its launchd job runs \(state.version): left running")
        case .refuse(let why), .hold(let why):
            log("agent-proxy: \(why): its launchd job (\(label)) left as it is")
        case .stop:
            await Launchctl.stop(label: label)
            try? FileManager.default.removeItem(atPath: plistPath)
            log("agent-proxy: settings.json has no agentProxy: its launchd job stopped and \(plistPath) removed")
        case .start, .restart:
            guard let executable = state.executable else { return }
            let why: String
            if case .restart(let said) = action { why = "started again (\(said))" } else { why = "started" }
            do {
                try FileManager.default.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                // Its log its owner's alone before launchd opens it (launchd would make it with the default mode).
                let file = open(logPath, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
                if file >= 0 { _ = fchmod(file, 0o600); close(file) }
                let job = job(label: label, executable: executable, version: state.version, settings: state.settings, log: logPath)
                try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
                    .write(to: URL(fileURLWithPath: plistPath), options: .atomic)
                await Launchctl.stop(label: label)
                let bootstrap = await Launchctl.run(["bootstrap", "gui/\(getuid())", plistPath])
                guard bootstrap?.status == 0 else {
                    log("agent-proxy: its launchd job couldn't be started: launchctl bootstrap: \(bootstrap?.output ?? "didn't run")")
                    return
                }
                log("agent-proxy: its launchd job \(why): \(executable) \(argument), \(state.version); its log \(logPath)")
            } catch {
                log("agent-proxy: its launchd job couldn't be written: \(error)")
            }
        }
    }
}
#endif
