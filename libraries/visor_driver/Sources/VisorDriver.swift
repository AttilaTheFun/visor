// Visor's server as agent_protocol's driver and dispatcher: one gRPC
// server, on its own port, serving AgentDriver (wrappers dial in) and
// AgentDispatcher (runners pull jobs). Started by the binary that runs the
// server (the menu bar app, the command-line server), never by the server
// library itself, which knows nothing of gRPC: listening as early as it can
// (VisorDriver.Listening), then serving the server once it is made.

import AgentProtocol
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import VisorServer
import VisorSystem

public enum VisorDriver {
    /// Listens on `host`:`port` and serves `server` at once: for a binary
    /// that has nothing to read before its server is made. (One that has
    /// listens first: `Listening.listen`, then `serve`.)
    @MainActor @discardableResult
    public static func start(_ server: VisorServer, host: String, port: Int, url: String, containerURL: String? = nil,
                             harness: String = "claude") -> Listening {
        let listening = Listening(host: host, port: port, url: url, containerURL: containerURL, harness: harness)
        listening.serve(server)
        return listening
    }

    /// Containers reach this computer's driver through Shireworks'
    /// agent-proxy by this name (it answers MultiPass's older
    /// `visor.multipass.internal` too, while MultiPass is retired).
    public static func containerURL(port: Int) -> String {
        "http://visor.agent.internal:\(port)"
    }

    /// The server's log, for what runs beside it (the native runner in an
    /// app whose module is outside the server's package).
    public static func log(_ line: String) {
        VisorServer.log(line)
    }
}
