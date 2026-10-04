/// Starting a program on a pseudo-terminal, as the system does it: a
/// terminal session's shell, with the terminal as its controlling terminal
/// so line editing, job control and Ctrl-C work as they do in a terminal
/// window.
public protocol TerminalLaunching: Sendable {
    /// Starts `command` in `directory`, with exactly `environment`, on a
    /// terminal of `cols` by `rows`.
    @MainActor
    func start(_ command: ShellCommand, directory: String, environment: [String: String], cols: Int, rows: Int) throws
        -> any TerminalChild
}
