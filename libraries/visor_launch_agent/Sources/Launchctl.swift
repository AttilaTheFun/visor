// This user's launchd, for Visor's LaunchAgents (LaunchAgentJob+Settle):
// agent-proxy's job and the server's (registered with SMAppService:
// ServerAgentService).

#if os(macOS)
import Darwin
import Foundation

/// This user's launchd, asked with launchctl.
public enum Launchctl {
    /// `gui/<uid>`: this user's domain.
    public static var domain: String { "gui/\(getuid())" }

    /// launchctl's status and what it said; nil when it couldn't run.
    public static func run(_ arguments: [String]) async -> (status: Int32, output: String)? {
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
    public static func runningState(label: String) async -> Bool? {
        guard let state = await run(["print", "\(domain)/\(label)"]) else { return nil }
        if state.status == 113 { return false }
        guard state.status == 0 else { return nil }
        return !state.output.contains("state = not running")
    }

    /// The job's process id while it runs; nil when it doesn't, or launchd
    /// couldn't say.
    public static func pid(label: String) async -> Int32? {
        guard let state = await run(["print", "\(domain)/\(label)"]), state.status == 0 else { return nil }
        return LaunchAgentJob.pid(inPrint: state.output)
    }

    /// Ended (TERM, then KILL after its ExitTimeOut) and removed; waits at
    /// most 40 seconds for it to go.
    public static func stop(label: String) async {
        let target = "\(domain)/\(label)"
        guard await run(["print", target])?.status == 0 else { return }
        _ = await run(["bootout", target])
        for _ in 0..<160 {
            guard await run(["print", target])?.status == 0 else { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Started now (`kickstart -k`: ended first if it runs): whether
    /// launchd had it to start.
    public static func kickstart(label: String) async -> Bool {
        await run(["kickstart", "-k", "\(domain)/\(label)"])?.status == 0
    }

    /// Loaded from its plist, and so started (RunAtLoad). What launchctl
    /// said when it couldn't be; nil once it is.
    public static func bootstrap(plist: String) async -> String? {
        let bootstrap = await run(["bootstrap", domain, plist])
        guard bootstrap?.status == 0 else { return "launchctl bootstrap: \(bootstrap?.output ?? "didn't run")" }
        return nil
    }
}
#endif
