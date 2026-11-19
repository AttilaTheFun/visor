// This user's launchd, for agent-proxy's job (AgentProxyJob+Settle).

#if os(macOS)
import Darwin
import Foundation

/// This user's launchd, asked with launchctl.
enum Launchctl {
    /// launchctl's status and what it said; nil when it couldn't run.
    static func run(_ arguments: [String]) async -> (status: Int32, output: String)? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: output, as: UTF8.self))
        }.value
    }

    /// Whether launchd has it and it hasn't ended: true or false when
    /// launchd says (113: no such job), nil when it couldn't.
    static func runningState(label: String) async -> Bool? {
        guard let state = await run(["print", "gui/\(getuid())/\(label)"]) else { return nil }
        if state.status == 113 { return false }
        guard state.status == 0 else { return nil }
        return !state.output.contains("state = not running")
    }

    /// Ended (TERM, then KILL after its ExitTimeOut) and removed; waits at
    /// most 40 seconds for it to go.
    static func stop(label: String) async {
        let target = "gui/\(getuid())/\(label)"
        guard await run(["print", target])?.status == 0 else { return }
        _ = await run(["bootout", target])
        for _ in 0..<160 {
            guard await run(["print", target])?.status == 0 else { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}
#endif
