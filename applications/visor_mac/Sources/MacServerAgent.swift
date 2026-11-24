// `Visor --server`: the server agent (docs/DEVELOPMENT.md, The server as a
// background agent). Visor.app's own executable run headless by this
// user's launchd (ServerAgentJob, settled by the app: LocalServer), with no
// AppKit UI: the same server the app runs (MacServer), with agent-proxy
// inside it (MacAgentProxy.foldIn) and the Sessions container's engine
// (MacSessionsContainer, its VM in this process: an update restarts it),
// restarted and updated by launchd
// (ServerAgentRestart). Its lines go to the system log, as the app's do, and
// to standard error, which it points at Visor-server.log in Visor's logs
// itself (on the Visor volume once it's there: MacPlaces), as its plist is
// the bundle's and names no path. Its data, cache and logs move onto the
// Visor volume at its start (MacPlaces.settle); with the volume expected
// and not mounted, it ends, for launchd to start it again.
//
// `Visor server-agent register`: the agent registered afresh with
// SMAppService from this bundle (0.64's plist removed, LaunchServices told
// of it again, unregistered, booted out, then registered:
// ServerAgentService.reregister), for the update's watcher after an update
// or a rollback, when SMAppService's launch constraint still names the
// bundle that was replaced. `Visor server-agent unregister`: stopped and
// unregistered (out of launchd and Background Items), and 0.64's plist
// removed, for Visor Disk Utility's Uninstall…, which can't unregister
// another app's agent itself.
//
// Sent TERM (launchd: the app handing the server back, a restart of the
// job, logging out; or anyone: `killall Visor` reaches it too, its process
// being Visor's), it steps aside as an in-place relaunch does: the agents
// under hosts are left running, for the next server to pick up. It then
// exits 1, so launchd's KeepAlive starts it again unless launchd itself
// was ending it: only `/api/quit` (an exit of 0) leaves it stopped.

import Darwin
import DiskVolumes
import Foundation
import Synchronization
import VisorLaunchAgent
import VisorProtocol
import VisorServer
import VisorServerPOSIX

@MainActor
enum MacServerAgent {
    /// Runs the server agent when `arguments` ask for it, and never returns
    /// then; returns otherwise, for the app to start.
    static func handle(_ arguments: [String]) {
        let given = Array(arguments.dropFirst())
        if given == [ServerAgentJob.command, "register"] {
            register()
        }
        if given == [ServerAgentJob.command, "unregister"] {
            unregister()
        }
        guard given.first == ServerAgentJob.argument else { return }
        run()
    }

    /// The agent stopped and unregistered, whatever the settings say; ends.
    private static func unregister() -> Never {
        let job = ServerAgentJob.job(bundleID: MacPlaces.own, logs: VisorFolders.locate().logs.path)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await ServerAgentService.removeLegacy(job: job, bundleID: MacPlaces.own, log: { print($0) })
            try? await ServerAgentService.service(bundleID: MacPlaces.own).unregister()
            await Launchctl.stop(label: job.label)
            done.signal()
        }
        done.wait()
        print("the server agent (\(job.label)) is stopped and unregistered")
        exit(0)
    }

    /// Registered afresh from this bundle (LaunchServices told of it again,
    /// unregistered, booted out, then registered, again until it runs:
    /// ServerAgentService.reregister), which starts it; ends. 0.64's plist
    /// goes first, as the app's launch takes it (ServerAgentService.settle):
    /// while it's there, Background Items keeps its item of the same label
    /// and macOS refuses the registration however long it's waited for, the
    /// rollback's too (the Mini's update to 0.67.1, 24 Nov: its 0.65.1 had
    /// come in by 0.64.1's watcher, which writes that plist).
    private static func register() -> Never {
        let bundleID = MacPlaces.own
        let job = ServerAgentJob.job(bundleID: bundleID, logs: VisorFolders.locate().logs.path)
        let problem = Mutex<String?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await ServerAgentService.removeLegacy(job: job, bundleID: bundleID, log: { print($0) })
            let said = await ServerAgentService.reregister(bundleID: bundleID)
            problem.withLock { $0 = said }
            done.signal()
        }
        done.wait()
        if let problem = problem.withLock({ $0 }) {
            FileHandle.standardError.write(Data("Visor: the server agent couldn't be registered: \(problem)\n".utf8))
            exit(1)
        }
        exit(0)
    }

    private static func run() -> Never {
        let job = ServerAgentJob.job(bundleID: MacPlaces.own, logs: VisorFolders.locate().logs.path)
        let missing = MacServer.prepare(lifecycle: ServerAgentRestart(job: job), runsServer: true, client: false, log: { line in
            FileHandle.standardError.write(Data("\(Date().formatted(.iso8601)) \(line)\n".utf8))
        })
        // Settled: the log is where Visor's logs are now.
        openLog(ServerAgentJob.job(bundleID: MacPlaces.own, logs: MacPlaces.folders.logs.path).log)
        let log = ServerPlatform.current.log
        if missing {
            log("the server agent ends for now: its data is on the Visor volume, which isn't mounted; launchd starts it again")
            exit(1)
        }
        log("the server agent \(VisorMacApp.bundleVersion) starting: process \(ProcessInfo.processInfo.processIdentifier), "
            + "\(Bundle.main.executablePath ?? "?")")
        // Another server on this Mac's data (the app's, still going): never
        // two at once. Waited for, then left to launchd, which starts this
        // again 5 seconds on.
        if !otherServerGone(within: 30) {
            log("another server still answers at \(VisorServer.socketPath) or on port \(Envelope.defaultPort): the server agent ends for now")
            exit(1)
        }
        let server = MacServer.make()
        POSIXStopSignals.onStop {
            Task { @MainActor in
                log("the server agent was sent TERM: it steps aside, for launchd to start it again unless launchd is ending it")
                await server.stepAside()
                exit(1)
            }
        }
        server.start()
        if !server.listening, server.password.isEmpty, !server.settings.asksNothing {
            log("the server agent has no password: it serves once one is set")
        }
        // The Sessions container's engine (docs/containers.md): given first,
        // so turning it on has given agent-proxy its relay port before
        // agent-proxy is folded in; started again once it is, if a session
        // is placed in it.
        let container = MacSessionsContainer(settings: server.settings, placed: { await server.placedInContainer })
        server.sessionsContainer = container
        Task {
            await MacAgentProxy.foldIn(server)
            await container.engine.serverStarted()
        }
        RunLoop.main.run()
        exit(0)
    }

    /// Standard output and error appended to `path` (its owner's alone),
    /// as launchd pointed them at the log when the plist named it.
    private static func openLog(_ path: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let file = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard file >= 0 else { return }
        dup2(file, STDOUT_FILENO)
        dup2(file, STDERR_FILENO)
        close(file)
    }

    /// Whether no other server answers, at the socket file (and 0.64's,
    /// `~/.visor/server.sock`) or on the port, within `seconds`.
    private static func otherServerGone(within seconds: Int) -> Bool {
        for _ in 0..<(seconds * 2) {
            if !POSIXUnixSocket.answers(VisorServer.socketPath), !POSIXUnixSocket.answers(VisorServer.legacySocketPath),
               !portAnswers(Envelope.defaultPort) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// Whether something listens on 127.0.0.1:`port`.
    private static func portAnswers(_ port: UInt16) -> Bool {
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
