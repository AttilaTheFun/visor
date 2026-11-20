// `Visor --server`: the server agent (docs/DEVELOPMENT.md, The server as a
// background agent). Visor.app's own executable run headless by this
// user's launchd (ServerAgentJob, settled by the app: LocalServer), with no
// AppKit UI: the same server the app runs (MacServer), with agent-proxy
// inside it (MacAgentProxy.foldIn), restarted and updated by launchd
// (ServerAgentRestart). Its lines go to the system log, as the app's do, and
// to standard error, which launchd points at ~/Library/Logs/Visor-server.log.
//
// Stopped by launchd (TERM: the app handing the server back, a restart of
// the job, logging out), it steps aside as an in-place relaunch does: the
// agents under hosts are left running, for the next server to pick up.

import Darwin
import Foundation
import VisorLaunchAgent
import VisorProtocol
import VisorServer
import VisorServerPOSIX

@MainActor
enum MacServerAgent {
    /// Runs the server agent when `arguments` ask for it, and never returns
    /// then; returns otherwise, for the app to start.
    static func handle(_ arguments: [String]) {
        guard arguments.dropFirst().first == ServerAgentJob.argument else { return }
        run()
    }

    private static func run() -> Never {
        let job = ServerAgentJob.job(bundleID: MacPlaces.own)
        MacServer.prepare(lifecycle: ServerAgentRestart(job: job), log: { line in
            FileHandle.standardError.write(Data("\(Date().formatted(.iso8601)) \(line)\n".utf8))
        })
        let log = ServerPlatform.current.log
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
                log("the server agent was asked to stop")
                await server.stepAside()
                exit(0)
            }
        }
        server.start()
        if !server.listening, server.password.isEmpty, !server.settings.asksNothing {
            log("the server agent has no password: it serves once one is set")
        }
        Task { await MacAgentProxy.foldIn(server) }
        RunLoop.main.run()
        exit(0)
    }

    /// Whether no other server answers, at the socket file or on the port,
    /// within `seconds`.
    private static func otherServerGone(within seconds: Int) -> Bool {
        for _ in 0..<(seconds * 2) {
            if !POSIXUnixSocket.answers(VisorServer.socketPath), !portAnswers(Envelope.defaultPort) { return true }
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
