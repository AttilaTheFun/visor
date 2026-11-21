// A session's agent in the Sessions container (step 4 places sessions
// there; this is what runs one): agent_protocol's agent-wrapper, from Visor's
// Linux programs at /opt/visor/bin, exec'd with the environment a runner
// gives it (agent_protocol's README; Shireworks' runner's
// AgentRunner.environment and ExecAgentHost) in the session's working
// folder, logging to `logs/<session>.log`:
//
// - AGENT_ID `<id>@<dispatcher>`, AGENT_JOB (the job's JSON, with its
//   driverURL), AGENT_RUNNER, and AGENT_DISPATCHER_URL when it reports;
// - AGENT_DRIVER_URL http://127.0.0.1:7434: relay-client's forward on the
//   guest's loopback to the driver link, so the same as on the Mac and
//   never through agent-proxy;
// - AGENT_TOKEN, the agent's JWT, there alone (never in AGENT_JOB or argv;
//   the wrapper unsets it once read);
// - AGENT_SESSIONS_DIR, Sessions (a job with no folder works in
//   `<Sessions>/Claude/<id>`), and AGENT_SOURCES_DIR when given;
// - TMPDIR /tmp: the wrapper's MCP socket (agent-mcp-*/mcp.sock, which
//   `agent-wrapper mcp` reaches through AGENT_MCP_SOCKET, set by the
//   wrapper for its harness) on the guest's own disk, not on Sessions'
//   virtiofs share; HOME /root (the image says none, and the processes run
//   as root);
// - AGENT_WRAPPER_CLAUDE only for a stand-in: `claude` is the image's, on
//   its PATH (/usr/local/bin/claude, npm's), which the exec keeps;
// - `--skip-permissions` unless the job says it asks (skipPermissions
//   false), as Shireworks' container runner does: the container is the
//   agent's sandbox (IS_SANDBOX=1 in the image).

import Foundation

extension ContainerEngine {
    /// The variables the wrapper's contract is made of: a session's own
    /// `environment` never sets these.
    public static let wrapperContract: Set<String> = [
        "AGENT_ID", "AGENT_JOB", "AGENT_DISPATCHER_URL", "AGENT_DRIVER_URL", "AGENT_RUNNER", "AGENT_TOKEN", "AGENT_SESSIONS_DIR",
        "AGENT_SOURCES_DIR", "AGENT_WRAPPER_CLAUDE", "AGENT_MCP_SOCKET",
    ]

    /// `session`'s agent-wrapper started in the container (started first
    /// if it isn't running). Its working folder, when it's under a folder
    /// shared at the same path, is made on the Mac first, as the exec
    /// starts in it.
    public func startWrapper(session: ContainerSession) async throws -> ContainerExecution {
        let request = Self.wrapperExec(session, sessions: context.sessions, checkouts: context.configuration().checkouts)
        if let folder = request.workingDirectory {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        return try await exec(request)
    }

    /// What `startWrapper` runs: agent-wrapper's argv, its environment over
    /// the image's, and its working folder (the session's, where it's under
    /// Sessions or the checkouts' folder, the guest seeing it at the same
    /// path; else the image's, and the wrapper makes the folder).
    public nonisolated static func wrapperExec(_ session: ContainerSession, sessions: String,
                                               checkouts: String? = nil) -> ContainerExec {
        var environment = session.environment.filter { !wrapperContract.contains($0.key) }
        environment["HOME"] = environment["HOME"] ?? "/root"
        environment["TMPDIR"] = "/tmp"
        environment["AGENT_ID"] = "\(session.id)@\(session.dispatcherURL)"
        environment["AGENT_JOB"] = session.jobJSON(driverURL: driverURL)
        environment["AGENT_DRIVER_URL"] = driverURL
        environment["AGENT_RUNNER"] = session.runner
        environment["AGENT_SESSIONS_DIR"] = sessions
        if let reportsTo = session.reportsTo, !reportsTo.isEmpty { environment["AGENT_DISPATCHER_URL"] = reportsTo }
        if let sources = session.sourcesDirectory, !sources.isEmpty { environment["AGENT_SOURCES_DIR"] = sources }
        if let token = session.token, !token.isEmpty { environment["AGENT_TOKEN"] = token }
        if let claude = session.claudeProgram, !claude.isEmpty { environment["AGENT_WRAPPER_CLAUDE"] = claude }
        let flags = session.skipPermissions == false ? [] : ["--skip-permissions"]
        let folder = session.workingDirectory.flatMap { folder in
            [sessions, checkouts].compactMap { $0 }.contains { Self.isInside(folder, $0) } ? folder : nil
        }
        return ContainerExec(id: session.id, arguments: [agentWrapper] + flags, environment: environment, workingDirectory: folder)
    }

    /// Whether `path` is `folder` or under it, with no `..` to leave it.
    nonisolated static func isInside(_ path: String, _ folder: String) -> Bool {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return false }
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return path == base || path.hasPrefix(base + "/")
    }
}
