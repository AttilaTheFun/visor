import Foundation

/// Commands run in the containers sessions lease from oss: straight to the
/// container over its socket on this computer (the lease's), not through
/// oss, so a command outlives oss's restarts. Given by the binary that runs
/// the server where it can (`ServerPlatform.containerExec`).
public protocol ContainerExecuting: Sendable {
    /// Runs `command` to its end in the container at `socket`, `input` its
    /// standard input: its status, and what it wrote to standard output and
    /// error.
    func execute(socket: String, _ command: [String], input: Data?) async throws -> (status: Int32, output: String)
    /// The command line, on this computer, that runs `executable` in the
    /// container at `socket`, in `directory` there, with the variables in
    /// the file at `environmentFile` on this computer: what an agent's host
    /// runs.
    func command(socket: String, executable: String, arguments: [String], directory: String,
                 environmentFile: String) -> ShellCommand
}
