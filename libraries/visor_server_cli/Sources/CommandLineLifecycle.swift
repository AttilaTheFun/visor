import Foundation
import VisorServer

/// How a command-line server is replaced: the new build (if there is one)
/// is put in this one's place, and it is started in the background to carry
/// on once this process has gone — the way this one was started, logging to
/// a file. Ending is exiting.
struct CommandLineLifecycle: ServerLifecycle {
    let system: any CommandLineSystem
    /// What this run was started with, after `run`.
    let options: ServerOptions
    /// Done before the process exits (the pid file).
    let cleanUp: @Sendable () -> Void

    @MainActor
    func relaunch(installing build: String?, carrying sessions: String) -> String? {
        if let build, !build.isEmpty {
            let source = (build as NSString).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: source) else { return "No program at \(source)" }
            if let problem = system.install(source, over: system.executable) { return problem }
        }
        var next = options
        next.after = ProcessInfo.processInfo.processIdentifier
        next.resume = sessions.isEmpty ? "all" : sessions
        let log = options.log ?? system.dataDirectory.appendingPathComponent("visor-server.log").path
        next.log = log
        do {
            _ = try system.startDetached(system.executable, ["run"] + next.arguments, log: log)
        } catch {
            return "Could not start the new server: \(error)"
        }
        return nil
    }

    @MainActor
    func terminate() {
        cleanUp()
        exit(0)
    }
}
