import Foundation

/// git as gh_mcp runs it: none of the user's or the system's config (no
/// url rewrites, no helpers of theirs), no prompts, no hooks and no
/// fsmonitor (a checkout's config is the agent's to write; nothing in it
/// may run on this Mac).
public struct Git: Sendable {
    public var executable: String
    public var searchPath: String
    public var home: String

    public init(executable: String = "git", searchPath: String? = nil, home: String = homeDirectory()) {
        self.executable = executable
        self.searchPath = searchPath ?? Self.searchPath(ProcessInfo.processInfo.environment["PATH"])
        self.home = home
    }

    /// The folders gh_mcp's LaunchAgent gave it (its PATH), each where git
    /// and unzip may be: the system's, then Homebrew's.
    public static let standardFolders = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin"]

    /// Where git and unzip are looked for: the process's PATH (in Visor,
    /// agent-proxy's: launchd gives a job /usr/bin:/bin:/usr/sbin:/sbin),
    /// then those of gh_mcp's PATH it lacks, so git is found as it was.
    static func searchPath(_ given: String?) -> String {
        var folders = (given ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for folder in standardFolders where !folders.contains(folder) { folders.append(folder) }
        return folders.joined(separator: ":")
    }

    public func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var environment = [
            "PATH": searchPath,
            "HOME": home,
            "LANG": "C",
            "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
        ]
        for (name, value) in extra { environment[name] = value }
        return environment
    }

    static let safety = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"]

    public func run(_ arguments: [String], in directory: String, environment extra: [String: String] = [:],
                    timeout: TimeInterval = 60) async throws -> ProcessResult {
        try await Run.run(executable, ["-C", directory] + Self.safety + arguments, environment: environment(extra), timeout: timeout)
    }

    /// Its output when it succeeds with some, else nil.
    public func value(_ arguments: [String], in directory: String) async throws -> String? {
        let result = try await run(arguments, in: directory)
        return result.succeeded && !result.output.isEmpty ? result.output : nil
    }
}
