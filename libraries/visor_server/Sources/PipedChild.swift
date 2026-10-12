// Child processes, the way the server runs them: a command asked a short
// question and read to its end, and an agent on pipes that is fed lines
// and read as it speaks. Reading never happens on the main actor; what is
// read comes back as a stream, in order.

import Foundation

/// An agent on pipes: JSON lines in on its standard input, bytes out on
/// its output and its errors, and how it ended.
@MainActor
final class PipedChild: AgentChild {
    private let process: Process
    private var input: FileHandle?
    let output: AsyncStream<Data>
    let errors: AsyncStream<Data>
    /// Nothing is done to an agent on the server's own pipes behind its
    /// back.
    let notices = AsyncStream<String> { $0.finish() }
    /// How it ended, once it has.
    let exit: Task<AgentExit, Never>

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    init(executable: String, arguments: [String], directory: String, environment: [String: String]) throws {
        let process = Process()
        let command = ServerPlatform.current.tools.command(executable, arguments)
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let (exits, exited) = AsyncStream.makeStream(of: AgentExit.self)
        process.terminationHandler = {
            exited.yield(AgentExit(status: $0.terminationStatus, signaled: $0.terminationReason == .uncaughtSignal))
            exited.finish()
        }
        self.output = output.fileHandleForReading.chunks
        self.errors = errors.fileHandleForReading.chunks
        do { try process.run() } catch { throw AgentProcessError.spawnFailed("\(error)") }
        self.process = process
        self.input = input.fileHandleForWriting
        exit = Task {
            for await exit in exits { return exit }
            return AgentExit(status: -1, signaled: false)
        }
    }

    func write(_ object: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        // A child that has gone leaves a pipe that cannot be written to;
        // its exit is what says so.
        try? input.write(contentsOf: data + Data([0x0A]))
    }

    func closeInput() {
        try? input?.close()
        input = nil
    }

    func end(grace: Duration) async {
        closeInput()
        let process = self.process
        let force = Task {
            try await Task.sleep(for: grace)
            if process.isRunning { process.terminate() }
            try await Task.sleep(for: .seconds(1))
            if process.isRunning { ServerPlatform.current.processes.kill(process.processIdentifier) }
        }
        _ = await exit.value
        force.cancel()
    }
}
