import Foundation
import VisorServer
import VisorServerPOSIX

/// Where a Linux user's tools are: their own bin directories and npm's
/// before the system's, and the login shell asked about the rest.
public struct LinuxTools: ToolLocating {
    public init() {}

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    public var directories: [String] {
        ["\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin", "/usr/local/bin", "/usr/bin", "/bin", "/snap/bin"]
    }

    public func searchPath(_ environment: [String: String]) -> [String] {
        (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    }

    public func fileNames(for tool: String) -> [String] { [tool] }

    public func ask(for tool: String) async -> String? {
        await POSIXUser.locate(tool, with: POSIXUser.loginShell(fallback: "/bin/sh"))
    }

    public var claudeManagedSettings: [String] { ["/etc/claude-code/managed-settings.json"] }

    public func environment(_ base: [String: String]) -> [String: String] {
        var environment = base
        let extra = ["\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin", "/usr/local/bin"]
        environment["PATH"] = ToolPath.searchPath(base["PATH"] ?? "/usr/bin:/bin", then: extra, separator: ":")
        return environment
    }

    public func searchPath(_ directory: String, before environment: [String: String]) -> [String: String] {
        var environment = environment
        environment["PATH"] = [directory, environment["PATH"]].compactMap { $0 }.joined(separator: ":")
        return environment
    }

    public func command(_ executable: String, _ arguments: [String]) -> ShellCommand {
        ShellCommand(executable, arguments)
    }
}
