import Foundation
import VisorServer
import VisorServerPOSIX

/// Where a Mac's developer tools are. An app started at login has none of
/// the developer directories on its PATH: Homebrew's and the user's own are
/// looked in directly, and the login shell (zsh) is asked about the rest.
public struct MacTools: ToolLocating {
    public init() {}

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    public var directories: [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin", "/usr/bin"]
    }

    public func fileNames(for tool: String) -> [String] { [tool] }

    public func ask(for tool: String) async -> String? {
        await POSIXUser.locate(tool, with: "/bin/zsh")
    }

    public var loginShell: ShellCommand {
        ShellCommand(POSIXUser.loginShell(fallback: "/bin/zsh"), ["-l"])
    }

    public func environment(_ base: [String: String]) -> [String: String] {
        var environment = base
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.claude/local"]
        environment["PATH"] = (extra + [base["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        return environment
    }

    public func command(_ executable: String, _ arguments: [String]) -> ShellCommand {
        ShellCommand(executable, arguments)
    }
}
