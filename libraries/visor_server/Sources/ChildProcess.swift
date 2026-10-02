// Child processes, the way the server runs them: a command asked a short
// question and read to its end, and an agent on pipes that is fed lines
// and read as it speaks. Reading never happens on the main actor; what is
// read comes back as a stream, in order.

import Foundation

/// Bytes into whole lines: a partial last line waits for the bytes that
/// finish it.
struct LineSplitter {
    private var buffer = Data()

    mutating func add(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let text = String(data: line, encoding: .utf8), !text.isEmpty { lines.append(text) }
        }
        return lines
    }

    /// What was written after the last newline, when the stream has ended.
    mutating func rest() -> String? {
        defer { buffer.removeAll() }
        guard !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }
}

extension FileHandle {
    /// What the other end of a pipe writes, as it writes it; the stream
    /// ends when that end closes.
    var chunks: AsyncStream<Data> {
        AsyncStream { continuation in
            readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { [weak self] _ in self?.readabilityHandler = nil }
        }
    }
}

extension AsyncStream where Element == Data {
    /// The lines of a stream of bytes, each read by `parse` into what it
    /// says (nothing, for a line of no interest). The reading is done off
    /// the caller's actor; only what the lines say crosses over.
    nonisolated func lines<Output: Sendable>(_ parse: @escaping @Sendable (String) -> [Output]) -> AsyncStream<Output> {
        AsyncStream<Output> { continuation in
            let reading = Task {
                var splitter = LineSplitter()
                for await chunk in self {
                    for line in splitter.add(chunk) {
                        for output in parse(line) { continuation.yield(output) }
                    }
                }
                if let line = splitter.rest() {
                    for output in parse(line) { continuation.yield(output) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in reading.cancel() }
        }
    }
}

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
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
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

    /// Waits for a process, ours or not, to exit: whether it had by the
    /// time `limit` passed.
    @concurrent
    static func exited(_ pid: pid_t, within limit: Duration) async -> Bool {
        let (exits, gone) = AsyncStream.makeStream(of: Void.self)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { gone.yield(); gone.finish() }
        source.resume()
        defer { source.cancel() }
        // Gone before anyone was watching.
        if kill(pid, 0) != 0 { return true }
        let timeout = Task { try? await Task.sleep(for: limit); gone.finish() }
        var exited = false
        for await _ in exits { exited = true }
        timeout.cancel()
        return exited
    }
}

/// An agent on pipes: JSON lines in on its standard input, bytes out on
/// its output and its errors, and how it ended.
@MainActor
final class PipedChild {
    struct Exit: Sendable {
        let status: Int32
        /// Ended by a signal rather than by exiting.
        let signaled: Bool
    }

    private let process: Process
    private var input: FileHandle?
    let output: AsyncStream<Data>
    let errors: AsyncStream<Data>
    /// How it ended, once it has.
    let exit: Task<Exit, Never>

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    init(executable: String, arguments: [String], directory: String, environment: [String: String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let (exits, exited) = AsyncStream.makeStream(of: Exit.self)
        process.terminationHandler = {
            exited.yield(Exit(status: $0.terminationStatus, signaled: $0.terminationReason == .uncaughtSignal))
            exited.finish()
        }
        self.output = output.fileHandleForReading.chunks
        self.errors = errors.fileHandleForReading.chunks
        do { try process.run() } catch { throw AgentProcessError.spawnFailed("\(error)") }
        self.process = process
        self.input = input.fileHandleForWriting
        exit = Task {
            for await exit in exits { return exit }
            return Exit(status: -1, signaled: false)
        }
    }

    /// One JSON object as a line on its standard input.
    func write(_ object: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        // A child that has gone leaves a pipe that cannot be written to;
        // its exit is what says so.
        try? input.write(contentsOf: data + Data([0x0A]))
    }

    /// End of input: an agent reading its standard input finishes what it
    /// is doing and exits.
    func closeInput() {
        try? input?.close()
        input = nil
    }

    /// Ends it and returns when it is gone: end of input first, then,
    /// `grace` later, a request to terminate, and a second after that no
    /// choice.
    func end(grace: Duration) async {
        closeInput()
        let process = self.process
        let force = Task {
            try await Task.sleep(for: grace)
            if process.isRunning { process.terminate() }
            try await Task.sleep(for: .seconds(1))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        _ = await exit.value
        force.cancel()
    }
}
