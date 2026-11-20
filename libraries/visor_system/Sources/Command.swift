import Foundation

/// A command run to its end for what it prints: the short questions the
/// server asks of the system (`ps`, the login shell).
package enum Command {
    /// The exit status and everything written to standard output (and to
    /// standard error, with `errors`); nil when the command could not be
    /// started. `input`, when given, is its standard input, then closed.
    @concurrent
    package static func output(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                       errors: Bool = false, input: Data? = nil) async -> (status: Int32, text: String)? {
        guard let ran = await run(executable, arguments, environment: environment, directory: nil, errors: errors, input: input, watch: nil)
        else { return nil }
        return (ran.status, ran.text)
    }

    /// As output, with `stop` asked every `interval` while the command
    /// runs: once it says so, the command is killed (which ends its output
    /// too) and `stopped` is true. For a command that could otherwise run
    /// on too long or too far (tar unpacking an archive that says less
    /// than it holds).
    @concurrent
    package static func output(_ executable: String, _ arguments: [String], errors: Bool = false, every interval: Duration,
                               stopping stop: @escaping @Sendable () -> Bool) async -> (status: Int32, text: String, stopped: Bool)? {
        await run(executable, arguments, environment: nil, directory: nil, errors: errors, input: nil, watch: (interval, stop))
    }

    /// As output, in `directory` with `environment`, `input` written to
    /// it, and `stop` asked every `interval` while it runs: a long call
    /// that can be cancelled (Super Compact's headless `claude -p`, its
    /// prompt on standard input).
    @concurrent
    package static func output(_ executable: String, _ arguments: [String], environment: [String: String], directory: URL, errors: Bool,
                               input: Data, every interval: Duration,
                               stopping stop: @escaping @Sendable () -> Bool) async -> (status: Int32, text: String, stopped: Bool)? {
        await run(executable, arguments, environment: environment, directory: directory, errors: errors, input: input, watch: (interval, stop))
    }

    @concurrent
    private static func run(_ executable: String, _ arguments: [String], environment: [String: String]?, directory: URL?, errors: Bool, input: Data?,
                            watch: (interval: Duration, stop: @Sendable () -> Bool)?) async -> (status: Int32, text: String, stopped: Bool)? {
        let process = Process()
        let command = SystemPlatform.current.tools.command(executable, arguments)
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = errors ? out : FileHandle.nullDevice
        let (statuses, exited) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { exited.yield($0.terminationStatus); exited.finish() }
        let chunks = out.fileHandleForReading.chunks
        let stdin = input.map { _ in Pipe() }
        if let stdin { process.standardInput = stdin }
        do { try process.run() } catch { return nil }
        // Written apart from the reading, so neither waits on the other.
        if let stdin, let input {
            let writer = stdin.fileHandleForWriting
            Task.detached {
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }
        let pid = process.processIdentifier
        let watcher = watch.map { interval, stop in
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { break }
                    if stop() {
                        SystemPlatform.current.processes.kill(pid)
                        return true
                    }
                }
                return false
            }
        }
        var data = Data()
        for await chunk in chunks { data.append(chunk) }
        var status: Int32 = -1
        for await value in statuses { status = value }
        watcher?.cancel()
        let stopped = await watcher?.value ?? false
        return (status, String(decoding: data, as: UTF8.self), stopped)
    }

    /// Starts a command, says `lines` to it, and reads what it says back,
    /// a line at a time, until `answer` finds what was asked for; then it
    /// is ended. Nil when it could not be started, said nothing of the
    /// kind, or took longer than `limit`.
    @concurrent
    package static func ask<Answer: Sendable>(_ executable: String, _ arguments: [String], saying lines: [String],
                                      environment: [String: String], within limit: Duration = .seconds(20),
                                      answer: @Sendable (String) -> Answer?) async -> Answer? {
        let process = Process()
        let command = SystemPlatform.current.tools.command(executable, arguments)
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
            SystemPlatform.current.processes.terminate(pid)
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
    package static func exited(_ pid: Int32, within limit: Duration) async -> Bool {
        let processes = SystemPlatform.current.processes
        let deadline = ContinuousClock.now + limit
        while processes.isRunning(pid) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }
}
