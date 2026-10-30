import Foundation

/// Commands run in a session's container, by its container host
/// (docs/container-host.md): one run to its end here, or an agent's command
/// line, which its host runs and keeps.
public protocol ContainerExecuting: Sendable {
    /// Runs `command` to its end in container `container`, `input` its
    /// standard input: its status, and what it wrote to standard output and
    /// error.
    func execute(container: String, _ command: [String], input: Data?) async throws -> (status: Int32, output: String)
    /// The command line, on this computer, that runs `executable` in
    /// container `container`, in `directory` there, with the variables in
    /// the file at `environmentFile` on this computer: what an agent's host
    /// runs.
    func command(container: String, executable: String, arguments: [String], directory: String,
                 environmentFile: String) -> ShellCommand
}
