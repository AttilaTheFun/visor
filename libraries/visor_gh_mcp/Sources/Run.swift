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
        // On a thread of its own, not Dispatch's shared pool: a call waits up
        // to `timeout` (600-900 s for a push or a rerun), and in Visor's
        // server dozens at once would leave the pool no thread for the rest
        // of the process.
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
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
        // Standard error read on a thread of its own (not Dispatch's pool,
        // as above), so neither pipe fills while the other is read; kept
        // behind a lock (Locked).
        let errors = Locked(Data())
        let read = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            errors.withLock { $0 = data }
            read.signal()
        }
        // The time limit: the process ended by its id (SIGTERM, as
        // Process.terminate sends), unless it has ended already; and, in
        // Visor, SIGKILL 5 s on if it is still there (a program that ignores
        // SIGTERM, as one started with it ignored does, would otherwise hold
        // its call, and its threads, for good). Timers alone: a work item
        // takes no thread until it fires, and then a moment.
        let pid = process.processIdentifier
        let state = Locked((ended: false, stopped: false))
        let stop: @Sendable (Int32) -> Void = { number in
            state.withLock { state in
                guard !state.ended else { return }
                state.stopped = true
                kill(pid, number)
            }
        }
        let deadline = DispatchWorkItem { stop(SIGTERM) }
        let last = DispatchWorkItem { stop(SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 5, execute: last)
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        read.wait()
        process.waitUntilExit()
        let stopped = state.withLock { state in
            state.ended = true
            return state.stopped
        }
        deadline.cancel()
        last.cancel()
        if stopped, process.terminationReason == .uncaughtSignal {
            throw ToolError.failed("\(URL(fileURLWithPath: executable).lastPathComponent) took longer than \(Int(timeout)) s and was stopped")
        }
        return ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: errors.withLock { $0 })
    }
}
