// What the server asks for when it starts an agent's host
// (visor-agent-host): the session, its folder and harness, the agent's
// command, its environment, its credential and the socket the host is to
// listen at. The server spawns the host itself (visor_agent's
// ProcessAgentHostSpawner, as it always has, native sessions included:
// docs/sandboxed.md); the value is JSON, so another spawner could be sent
// it over a socket. After the spawn, everything is the host's wire
// (AgentHostFrame) as before.
//
// The JSON, version 1:
//
//   {"version": 1,
//    "session": "<Visor session id>",
//    "folder": "<the agent's working folder>",
//    "harness": "claude" | "codex" | "<another tool's name>",
//    "executable": "<the agent's program>", "arguments": ["…"],
//    "environment": {"…": "…"},            (without the two below)
//    "token": "<the session's JWT>",        (VISOR_TOKEN; may be absent)
//    "tokenFile": "<its token file's path>",  (VISOR_TOKEN_FILE; may be absent)
//    "socket": "<the host's socket's path>", (under 104 bytes)
//    "memoryLimit": <bytes; 0 for none>,
//    "log": "<the hosts' log, the host's output appended>"}
//
// The credential is apart from the rest of the environment so a spawner
// can tell what it carries (a JWT minted for the session, or the file it's
// re-minted into) and never logs it; the host's process is given both back
// as they were (`processEnvironment`).

/// A request to start an agent's host.
public struct AgentHostSpawnRequest: Codable, Equatable, Sendable {
    /// The request's version: a spawner takes only one it knows.
    public var version: Int
    /// The Visor session the agent is for.
    public var session: String
    /// The agent's working folder (the host's too).
    public var folder: String
    /// Which harness the agent is (`claude`, `codex`, …): what a spawner
    /// may allow or refuse.
    public var harness: String
    /// The agent's program and its arguments, as the host runs them.
    public var executable: String
    public var arguments: [String]
    /// The agent's environment, without its credential.
    public var environment: [String: String]
    /// The session's token (a JWT), when the agent is given it itself.
    public var token: String?
    /// The file the session's token is kept fresh in, when there is one.
    public var tokenFile: String?
    /// The socket the host listens at, which the server connects to.
    public var socket: String
    /// The most memory the agent and what it runs may use (0: no limit).
    public var memoryLimit: UInt64
    /// The hosts' log, the host's output and errors appended to it.
    public var log: String

    public static let currentVersion = 1
    /// The environment's names the credential is kept under.
    public static let tokenVariable = "VISOR_TOKEN"
    public static let tokenFileVariable = "VISOR_TOKEN_FILE"

    /// A request whose credential is taken out of `environment`
    /// (VISOR_TOKEN, VISOR_TOKEN_FILE) into its own fields.
    public init(session: String, folder: String, harness: String, executable: String, arguments: [String],
                environment: [String: String], socket: String, memoryLimit: UInt64, log: String) {
        var rest = environment
        token = rest.removeValue(forKey: Self.tokenVariable)
        tokenFile = rest.removeValue(forKey: Self.tokenFileVariable)
        version = Self.currentVersion
        self.session = session
        self.folder = folder
        self.harness = harness
        self.executable = executable
        self.arguments = arguments
        self.environment = rest
        self.socket = socket
        self.memoryLimit = memoryLimit
        self.log = log
    }

    /// The host's process's environment: the agent's, with its credential
    /// back as it was given.
    public var processEnvironment: [String: String] {
        var all = environment
        if let token { all[Self.tokenVariable] = token }
        if let tokenFile { all[Self.tokenFileVariable] = tokenFile }
        return all
    }

    /// The host's arguments: where it listens, its folder, its memory
    /// limit, and the agent's command after `--`.
    public var hostArguments: [String] {
        ["--socket", socket, "--directory", folder, "--memory-limit", String(memoryLimit), "--", executable] + arguments
    }
}
