import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Programs run for the tools (git, agent-token, unzip), off Swift's
/// cooperative threads, with an environment given whole and a time limit.
public enum Run {
    /// `executable` is a path, or a name looked up on the environment's
    /// PATH (through /usr/bin/env).
    public static func run(
        _ executable: String, _ arguments: [String], environment: [String: String]? = nil,
        directory: String? = nil, timeout: TimeInterval = 120
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    continuation.resume(returning: try runBlocking(executable, arguments, environment: environment, directory: directory, timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func runBlocking(
        _ executable: String, _ arguments: [String], environment: [String: String]?, directory: String?, timeout: TimeInterval
    ) throws -> ProcessResult {
        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ToolError.failed("\(executable) could not be run: \(error.localizedDescription)")
        }
        // Standard error read on a thread of its own, so neither pipe fills
        // while the other is read; in Visor, kept behind a lock (Locked).
        let errors = Locked(Data())
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            errors.withLock { $0 = data }
            group.leave()
        }
        // The time limit: the process ended by its id (SIGTERM, as
        // Process.terminate sends), unless it has ended already.
        let pid = process.processIdentifier
        let ended = Locked(false)
        let deadline = DispatchWorkItem {
            ended.withLock { ended in
                if !ended { kill(pid, SIGTERM) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        ended.withLock { $0 = true }
        deadline.cancel()
        if process.terminationReason == .uncaughtSignal, process.terminationStatus == SIGTERM {
            throw ToolError.failed("\(URL(fileURLWithPath: executable).lastPathComponent) took longer than \(Int(timeout)) s and was stopped")
        }
        return ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: errors.withLock { $0 })
    }
}
