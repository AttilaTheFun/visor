import Foundation

/// Where an agent is started: under a host of its own where the platform
/// has one (HostedChild), so it outlives the server; otherwise on the
/// server's own pipes (PipedChild).
@MainActor
enum AgentChildren {
    /// The most memory a session's agent and what it runs may use, in
    /// bytes (0: no limit): the host's memory guard holds it to this.
    static var memoryLimit: UInt64 = defaultMemoryLimit

    /// Half the computer's memory: room for the rest of it, and for the
    /// other sessions, when one runs away.
    static var defaultMemoryLimit: UInt64 { ProcessInfo.processInfo.physicalMemory / 2 }

    /// Where the hosts' sockets and their log are.
    static var folder: URL { VisorServer.storeURL.deletingLastPathComponent().appendingPathComponent("hosts", isDirectory: true) }

    /// `session` is the Visor session the agent is for: an agent with one is
    /// hosted, where there are hosts.
    static func start(executable: String, arguments: [String], directory: String, environment: [String: String],
                      session: String?) throws -> any AgentChild {
        if let session, let hosting = ServerPlatform.current.agentHosts {
            let command = ServerPlatform.current.tools.command(executable, arguments)
            return try HostedChild.start(executable: command.executable, arguments: command.arguments, directory: directory,
                                         environment: environment, session: session, in: folder, memoryLimit: memoryLimit,
                                         hosting: hosting)
        }
        return try PipedChild(executable: executable, arguments: arguments, directory: directory, environment: environment)
    }
}
