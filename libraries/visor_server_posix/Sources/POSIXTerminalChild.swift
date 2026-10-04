import CVisorPOSIX
import Foundation
import VisorServer

/// A program on a pseudo-terminal: the master end here, the slave its
/// controlling terminal.
@MainActor
final class POSIXTerminalChild: TerminalChild {
    let processID: Int32
    private let master: GuardedDescriptor
    /// The other end, held open: it is the terminal (macOS's master refuses
    /// TIOCSWINSZ), and while it is held the master never sees the end of
    /// the stream just because the program closed its own. Closed once the
    /// program has gone, which ends the reading.
    private let terminal: GuardedDescriptor
    let output: AsyncStream<Data>
    /// Done once it has exited and been reaped.
    private let exit: Task<Void, Never>
    private(set) var hasExited = false

    init(_ command: ShellCommand, directory: String, environment: [String: String], cols: Int, rows: Int) throws {
        var name = [CChar](repeating: 0, count: 1024)
        let master = visor_open_terminal(&name, name.count)
        guard master >= 0 else { throw AgentProcessError.spawnFailed("could not open a pseudo-terminal") }
        let slavePath = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        // Our own handle on the terminal, opened before the program starts
        // so its first paint is already the right shape.
        let terminal = open(slavePath, O_RDWR | O_NOCTTY)
        guard terminal >= 0 else {
            close(master)
            throw AgentProcessError.spawnFailed("could not open the terminal")
        }
        _ = fcntl(terminal, F_SETFD, FD_CLOEXEC)
        _ = visor_set_terminal_size(terminal, UInt16(clamping: cols), UInt16(clamping: rows))

        // The leader of a new session whose controlling terminal is this
        // one, so Ctrl-C, job control, line editing and resize signals all
        // work; in its own directory, with nothing else of ours inherited.
        let argv = ([command.executable] + command.arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        let child = visor_spawn_on_terminal(command.executable, argv, envp, directory, terminal)
        guard child > 0 else {
            let reason = String(cString: strerror(errno))
            close(terminal)
            close(master)
            throw AgentProcessError.spawnFailed("\((command.executable as NSString).lastPathComponent) could not be started (\(reason))")
        }
        processID = child
        self.master = GuardedDescriptor(master)
        self.terminal = GuardedDescriptor(terminal)

        // The program's own end is held open here, so the stream never ends
        // on its own: the process itself says when it is gone.
        output = Self.reading(self.master)
        let exits = Self.watching(child, terminal: self.terminal)
        exit = Task { for await _ in exits {} }
        Task { [weak self] in
            await self?.exit.value
            self?.hasExited = true
        }
    }

    /// What the terminal draws, read on a thread of its own as it is drawn,
    /// until the terminal's other end has closed; then the master closes.
    private nonisolated static func reading(_ master: GuardedDescriptor) -> AsyncStream<Data> {
        let (output, drawn) = AsyncStream.makeStream(of: Data.self)
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                // Only this thread closes the master, so it is open here.
                let count = read(master.number, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                drawn.yield(Data(buffer[0..<count]))
            }
            master.close()
            drawn.finish()
        }
        return output
    }

    /// The program's exit: it is reaped (on a thread of its own, which
    /// waits for nothing else), our end of its terminal closes — which ends
    /// the reading once whatever it started has let go too — and the stream
    /// returned ends.
    private nonisolated static func watching(_ child: Int32, terminal: GuardedDescriptor) -> AsyncStream<Void> {
        let (exits, gone) = AsyncStream.makeStream(of: Void.self)
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0, errno == EINTR {}
            terminal.close()
            gone.finish()
        }
        return exits
    }

    func exited() async {
        await exit.value
    }

    func resize(cols: Int, rows: Int) {
        terminal.use { _ = visor_set_terminal_size($0, UInt16(clamping: cols), UInt16(clamping: rows)) }
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        master.use { writeAll($0, data) }
    }

    func end(grace: Duration) async {
        guard !hasExited else { return }
        let pid = processID
        signalProcess(pid, SIGTERM)
        let force = Task {
            try await Task.sleep(for: grace)
            signalProcess(pid, SIGKILL)
        }
        await exit.value
        force.cancel()
    }
}
