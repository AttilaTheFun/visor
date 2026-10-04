import Foundation

/// A command run to its end for what it prints: the short questions the
/// server asks of the system (`ps`, the login shell).
enum Command {
    /// The exit status and everything written to standard output (and to
    /// standard error, with `errors`); nil when the command could not be
    /// started.
    @concurrent
    static func output(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                       errors: Bool = false) async -> (status: Int32, text: String)? {
        let process = Process()
        let command = ServerPlatform.current.tools.command(executable, arguments)
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        if let environment { process.environment = environment }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = errors ? out : FileHandle.nullDevice
        let (statuses, exited) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { exited.yield($0.terminationStatus); exited.finish() }
        let chunks = out.fileHandleForReading.chunks
        do { try process.run() } catch { return nil }
        var data = Data()
        for await chunk in chunks { data.append(chunk) }
        var status: Int32 = -1
        for await value in statuses { status = value }
        return (status, String(decoding: data, as: UTF8.self))
    }

    /// Starts a command, says `lines` to it, and reads what it says back,
    /// a line at a time, until `answer` finds what was asked for; then it
    /// is ended. Nil when it could not be started, said nothing of the
    /// kind, or took longer than `limit`.
    @concurrent
    static func ask<Answer: Sendable>(_ executable: String, _ arguments: [String], saying lines: [String],
                                      environment: [String: String], within limit: Duration = .seconds(20),
                                      answer: @Sendable (String) -> Answer?) async -> Answer? {
        let process = Process()
        let command = ServerPlatform.current.tools.command(executable, arguments)
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let chunks = output.fileHandleForReading.chunks
        do { try process.run() } catch { return nil }
        for line in lines { try? input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8)) }
        // Never waits long: one that does not answer is ended, which ends
        // what it says.
        let pid = process.processIdentifier
        let deadline = Task {
            try await Task.sleep(for: limit)
            ServerPlatform.current.processes.terminate(pid)
        }
        defer { deadline.cancel() }
        var splitter = LineSplitter()
        var found: Answer?
        reading: for await chunk in chunks {
            for line in splitter.add(chunk) {
                if let answered = answer(line) {
                    found = answered
                    break reading
                }
            }
        }
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        return found
    }

    /// Waits for a process, ours or not, to exit: whether it had by the
    /// time `limit` passed. Asked a few times a second.
    @concurrent
    static func exited(_ pid: Int32, within limit: Duration) async -> Bool {
        let processes = ServerPlatform.current.processes
        let deadline = ContinuousClock.now + limit
        while processes.isRunning(pid) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }
}
