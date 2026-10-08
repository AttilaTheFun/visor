/// Where the agents' command-line tools are, and the user's shell, as the
/// system has them: the directories they are installed in, the names their
/// files have, how the system is asked about one that is elsewhere, and
/// how one is started.
public protocol ToolLocating: Sendable {
    /// Directories looked in directly, in order, after the server's own
    /// search path.
    var directories: [String] { get }
    /// The directories on the search path in `environment` (its PATH), in
    /// order: whoever starts the server can put a tool there — a wrapper
    /// script — and it is found before the usual directories.
    func searchPath(_ environment: [String: String]) -> [String]
    /// The file names a tool may have ("claude"; "claude.exe" or
    /// "claude.cmd" where programs carry their kind in their name).
    func fileNames(for tool: String) -> [String]
    /// Asks the system where a tool is (the login shell, which knows the
    /// user's PATH); nil when it does not know. Takes a while.
    func ask(for tool: String) async -> String?
    /// The user's shell, as a terminal session starts it.
    var loginShell: ShellCommand { get }
    /// The environment a tool is started with: `base` with the tool
    /// directories on its search path.
    func environment(_ base: [String: String]) -> [String: String]
    /// How to start `executable` with `arguments` (a script goes through
    /// its interpreter where the system does not start one itself).
    func command(_ executable: String, _ arguments: [String]) -> ShellCommand
}
