// Visor's server as agent_protocol's driver and dispatcher: one gRPC
// server, on its own port, serving AgentDriver (wrappers dial in) and
// AgentDispatcher (runners pull jobs). Started by the binary that runs the
// server (the menu bar app, the command-line server), never by the server
// library itself, which knows nothing of gRPC.

import AgentProtocol
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import VisorServer

public enum VisorDriver {
    /// Serves on `host`:`port` until the task is cancelled, and gives the
    /// server its driven sessions' processes and its job queue. `url` is
    /// this server's address as wrappers and runners reach it. `harness`
    /// is what its jobs run ("echo" for a test without a model).
    /// `containerURL` is this server's address as containers reach it
    /// (MultiPass's dial-in, `http://visor.multipass.internal:<port>`),
    /// given to container runners in place of `url`; nil for the same.
    @MainActor
    public static func start(_ server: VisorServer, host: String, port: Int, url: String, containerURL: String? = nil,
                             harness: String = "claude") -> Task<Void, Never> {
        let jobs = JobQueue(dispatcherURL: url, driverURL: url, containerURL: containerURL, harness: harness)
        server.jobs = jobs
        server.drivenProcess = { _ in DrivenProcess() }
        return Task.detached {
            // A ping every two minutes on a quiet connection: the relays
            // between a container's wrapper and here (Shireworks' and
            // MultiPass's) close one that is quiet for ten (13 Nov: a
            // moved session's wrapper redialled every ten minutes).
            let transport = HTTP2ServerTransport.Posix(address: .ipv4(host: host, port: port), transportSecurity: .plaintext,
                                                       config: .defaults { $0.connection.keepalive.time = .seconds(120) })
            do {
                try await withGRPCServer(transport: transport, services: [DriverService(server: server, jobs: jobs), DispatcherService(jobs: jobs)]) { _ in
                    VisorServer.log("agent_protocol: driver and dispatcher on \(host):\(port), as \(url)"
                        + (containerURL.map { ", and to containers as \($0)" } ?? ""))
                    while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
                }
            } catch {
                VisorServer.log("agent_protocol: the driver and dispatcher couldn't serve on \(host):\(port): \(error)")
            }
        }
    }

    /// The server's log, for what runs beside it (the native runner in an
    /// app whose module is outside the server's package).
    public static func log(_ line: String) {
        VisorServer.log(line)
    }
}
