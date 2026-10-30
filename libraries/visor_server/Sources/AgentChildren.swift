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
    /// hosted, when agents are detached. With `container`, the agent runs
    /// in that container (`executable` by its name on the container's
    /// path), under a host here like any other: its variables, and the
    /// sign-ins for containers, in a file only this user reads.
    static func start(executable: String, arguments: [String], directory: String, environment: [String: String],
                      session: String?, container: ContainerPlacement? = nil) throws -> any AgentChild {
        var command = ServerPlatform.current.tools.command(executable, arguments)
        var environment = environment
        if let container {
            let file = try writeEnvironment(environment.merging(ContainerSignIns.environment()) { ours, _ in ours },
                                            for: session ?? container.id)
            command = container.exec.command(container: container.id, executable: executable, arguments: arguments, directory: directory,
                                             environmentFile: file.path)
            environment = ToolPath.environment()
        }
        if detach, let session {
            if let problem = hostProblem() { throw AgentProcessError.spawnFailed(undetachable(problem)) }
            guard let hosting = ServerPlatform.current.agentHosts else { throw AgentProcessError.spawnFailed(undetachable("this system has no agent host")) }
            return try HostedChild.start(executable: command.executable, arguments: command.arguments, directory: directory,
                                         environment: environment, session: session, in: folder, memoryLimit: memoryLimit,
                                         hosting: hosting)
        }
        return try PipedChild(executable: command.executable, arguments: command.arguments, directory: directory, environment: environment)
    }

    /// Writes an agent's variables for its container, readable by this
    /// user alone: the file the container's tool reads them from.
    private static func writeEnvironment(_ environment: [String: String], for session: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(session + ".env", isDirectory: false)
        let lines = environment.filter { !$0.value.contains("\n") }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)\n" }.joined()
        guard FileManager.default.createFile(atPath: file.path, contents: Data(lines.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw AgentProcessError.spawnFailed("Visor could not write the agent's variables for its container to \(file.path)")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }
}
