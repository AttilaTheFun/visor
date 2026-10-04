import Foundation
import VisorServer

/// Where a Windows user's tools are: their own bin directory, npm's, the
/// usual install places; `where` asked about the rest. A tool that is a
/// script (npm's `.cmd` shims) is started through cmd.
public struct WindowsTools: ToolLocating {
    public init() {}

    /// A variable from the environment, its name in any case.
    static func variable(_ name: String) -> String? {
        ProcessInfo.processInfo.environment.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var directories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var directories = ["\(home)\\.local\\bin", "\(home)\\.claude\\local"]
        if let roaming = Self.variable("APPDATA") { directories.append("\(roaming)\\npm") }
        if let local = Self.variable("LOCALAPPDATA") { directories.append("\(local)\\Programs\\nodejs") }
        return directories + ["C:\\Program Files\\nodejs", "C:\\Program Files\\Git\\cmd"]
    }

    public func fileNames(for tool: String) -> [String] {
        [tool + ".exe", tool + ".cmd", tool + ".bat", tool]
    }

    public func ask(for tool: String) async -> String? {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\where.exe")
                process.arguments = [tool]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return continuation.resume(returning: nil) }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let first = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init)
                continuation.resume(returning: process.terminationStatus == 0 ? first : nil)
            }
        }
    }

    /// Windows PowerShell, which every Windows has.
    public var loginShell: ShellCommand {
        ShellCommand("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", ["-NoLogo"])
    }

    public func environment(_ base: [String: String]) -> [String: String] {
        var environment = base
        let key = base.keys.first { $0.caseInsensitiveCompare("PATH") == .orderedSame } ?? "Path"
        environment[key] = (directories + [base[key] ?? ""]).joined(separator: ";")
        return environment
    }

    public func command(_ executable: String, _ arguments: [String]) -> ShellCommand {
        let kind = (executable as NSString).pathExtension.lowercased()
        guard kind == "cmd" || kind == "bat" else { return ShellCommand(executable, arguments) }
        let shell = Self.variable("COMSPEC") ?? "C:\\Windows\\System32\\cmd.exe"
        return ShellCommand(shell, ["/d", "/c", executable] + arguments)
    }
}
