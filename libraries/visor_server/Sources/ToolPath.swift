import Foundation
import Synchronization
import VisorProtocol

/// Where the agents' command-line tools live. A server started by the
/// system has little on its PATH: the platform's usual directories are
/// looked in directly, and the system (the login shell) is asked about a
/// tool they do not have.
public enum ToolPath {
    /// What the system said of each tool it was asked about: where it is,
    /// or that it is not there.
    private static let asked = Mutex<[String: String?]>([:])

    /// Where a tool is, as far as is known without waiting: in one of the
    /// usual directories, or where the system last found it.
    public static func resolve(_ name: String) -> String? {
        let tools = ServerPlatform.current.tools
        for directory in tools.directories {
            for file in tools.fileNames(for: name) {
                let path = (directory as NSString).appendingPathComponent(file)
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        return asked.withLock { $0[name] ?? nil }
    }

    /// Asks the system where the tools are that the usual directories do
    /// not have, and remembers what it says. That takes a while, so it is
    /// done ahead of need and off the main actor.
    @concurrent
    public static func locate(_ names: [String]) async {
        for name in names where resolve(name) == nil {
            let found = await ServerPlatform.current.tools.ask(for: name)
            asked.withLock { $0[name] = found }
        }
    }

    /// The shell a terminal session runs: the user's own.
    public static func loginShell() -> ShellCommand {
        ServerPlatform.current.tools.loginShell
    }

    /// The environment for a spawned agent: ours, with the tool
    /// directories on its search path and any trace of a surrounding
    /// Claude Code session removed (a nested session refuses to start).
    public static func environment() -> [String: String] {
        var env = ServerPlatform.current.tools.environment(ProcessInfo.processInfo.environment)
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") { env.removeValue(forKey: key) }
        return env
    }
}
