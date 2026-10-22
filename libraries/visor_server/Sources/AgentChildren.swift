import Foundation

/// Where an agent is started: under a host of its own (HostedChild), so it
/// outlives the server — unless detaching is turned off
/// (VisorServer.detachesAgents), when it is on the server's own pipes
/// (PipedChild). Never the one in place of the other: an agent that is to
/// be detached and cannot be is not started, and says why.
@MainActor
enum AgentChildren {
    /// Whether agents run under hosts, as the server was set (on unless
    /// turned off).
    static var detach = true
    /// The most memory a session's agent and what it runs may use, in
    /// bytes (0: no limit): the host's memory guard holds it to this.
    static var memoryLimit: UInt64 = defaultMemoryLimit

    /// Half the computer's memory: room for the rest of it, and for the
    /// other sessions, when one runs away.
    static var defaultMemoryLimit: UInt64 { ProcessInfo.processInfo.physicalMemory / 2 }

    /// Where the hosts' sockets and their log are.
    static var folder: URL { VisorServer.storeURL.deletingLastPathComponent().appendingPathComponent("hosts", isDirectory: true) }

    /// Why hosts cannot be started, as found the first time one was
    /// wanted (the program does not change while the server runs).
    private static var checked: (program: String, problem: String?)?

    /// What stops agents running under hosts here; nil when nothing does.
    static func hostProblem() -> String? {
        guard let hosting = ServerPlatform.current.agentHosts else { return "this system has no agent host" }
        if let checked, checked.program == hosting.program { return checked.problem }
        let problem = hosting.problem()
        checked = (hosting.program, problem)
        return problem
    }

    /// What an agent that cannot be detached says.
    static func undetachable(_ problem: String) -> String {
        "Visor could not start this agent apart from the server: \(problem). Turn off “Run agents apart from the server” in Visor "
            + "Server's settings, or set VISOR_DETACH_AGENT_HOST=0, to run agents as the server's own children."
    }

    /// `session` is the Visor session the agent is for: an agent with one is
    /// hosted, when agents are detached. With `container`, it runs in that
    /// container on oss instead, kept there whatever this server does.
    static func start(executable: String, arguments: [String], directory: String, environment: [String: String],
                      session: String?, container: ContainerPlacement? = nil) throws -> any AgentChild {
        if let container {
            return OSSChild.start(client: container.client, container: container.container, command: [executable] + arguments,
                                  environment: environment, directory: directory)
        }
        if detach, let session {
            if let problem = hostProblem() { throw AgentProcessError.spawnFailed(undetachable(problem)) }
            guard let hosting = ServerPlatform.current.agentHosts else { throw AgentProcessError.spawnFailed(undetachable("this system has no agent host")) }
            let command = ServerPlatform.current.tools.command(executable, arguments)
            return try HostedChild.start(executable: command.executable, arguments: command.arguments, directory: directory,
                                         environment: environment, session: session, in: folder, memoryLimit: memoryLimit,
                                         hosting: hosting)
        }
        return try PipedChild(executable: executable, arguments: arguments, directory: directory, environment: environment)
    }
}
