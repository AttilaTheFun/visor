/// How a host was started:
///     visor-agent-host --socket <path> [--memory-limit <bytes>] [--directory <dir>] -- <agent> <arguments…>
/// The agent is given the host's own environment.
public struct AgentHostOptions: Equatable, Sendable {
    /// Where the host listens for the server.
    public var socket: String
    /// Where the agent runs.
    public var directory: String?
    /// The most memory the agent and what it runs may use, in bytes (0: no
    /// limit). The server says it again each time it connects.
    public var memoryLimit: UInt64
    /// The agent's program and its arguments.
    public var executable: String
    public var arguments: [String]

    public init(socket: String, directory: String? = nil, memoryLimit: UInt64 = 0, executable: String, arguments: [String]) {
        self.socket = socket
        self.directory = directory
        self.memoryLimit = memoryLimit
        self.executable = executable
        self.arguments = arguments
    }

    /// The options in a command line (without the program's own name); nil
    /// when they are not complete.
    public init?(_ words: [String]) {
        var socket: String?
        var directory: String?
        var limit: UInt64 = 0
        var index = words.startIndex
        while index < words.endIndex {
            let word = words[index]
            let value = index + 1 < words.endIndex ? words[index + 1] : nil
            switch word {
            case "--":
                let agent = Array(words[(index + 1)...])
                guard let socket, let executable = agent.first else { return nil }
                self.init(socket: socket, directory: directory, memoryLimit: limit, executable: executable, arguments: Array(agent.dropFirst()))
                return
            case "--socket": socket = value
            case "--directory": directory = value
            case "--memory-limit": limit = value.flatMap { UInt64($0) } ?? 0
            default: return nil
            }
            index += 2
        }
        return nil
    }
}
