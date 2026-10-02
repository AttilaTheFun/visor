import Foundation
import Synchronization
import VisorProtocol

/// Where the agents' command-line tools live. A GUI app's PATH has none of
/// the developer directories: the usual ones are looked in directly, and
/// the login shell is asked about a tool they do not have.
public enum ToolPath {
    /// What the login shell said of each tool it was asked about: where it
    /// is, or that it is not there.
    private static let asked = Mutex<[String: String?]>([:])

    private static var directories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin", "/usr/bin"]
    }

    /// Where a tool is, as far as is known without waiting: in one of the
    /// usual directories, or where the login shell last found it.
    public static func resolve(_ name: String) -> String? {
        for directory in directories where FileManager.default.isExecutableFile(atPath: "\(directory)/\(name)") {
            return "\(directory)/\(name)"
        }
        return asked.withLock { $0[name] ?? nil }
    }

    /// Asks the login shell where the tools are that the usual directories
    /// do not have, and remembers what it says. Starting a login shell
    /// takes a while, so this is done ahead of need and off the main actor.
    @concurrent
    public static func locate(_ names: [String]) async {
        for name in names where resolve(name) == nil {
            let answer = await Command.output("/bin/zsh", ["-lc", "command -v \(name)"])
            let path = answer?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let found = answer?.status == 0 && !path.isEmpty
            asked.withLock { $0[name] = found ? path : nil }
        }
    }

    /// The environment for a spawned agent: ours, with the developer
    /// directories on PATH and any trace of a surrounding Claude Code
    /// session removed (a nested session refuses to start).
    public static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.claude/local"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") { env.removeValue(forKey: key) }
        return env
    }
}
