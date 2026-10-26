import Foundation

/// The Linux containers this computer runs, which a session's agent can run
/// in (Apple's container on a Mac): given by the binary that runs the
/// server where there are any (`ServerPlatform.containers`).
public protocol ContainerRunning: Sendable {
    /// Why no container can be run here now (the tool is not installed, or
    /// its service is not started); nil when one can.
    func problem() async -> String?
    /// Makes and starts a container, kept running, doing nothing, until it
    /// is removed.
    func run(_ spec: ContainerSpec) async throws
    /// Whether the container is there (nil when not) and running.
    func isRunning(_ name: String) async -> Bool?
    /// Removes the container, stopping it first, and its disk unless it is
    /// kept for the container made again in its place.
    func remove(_ name: String, keepingDisk: Bool) async throws
    /// Runs `command` in the container to its end, `input` its standard
    /// input: its status, and what it wrote to standard output and error.
    func execute(_ name: String, _ command: [String], input: Data?) async throws -> (status: Int32, output: String)
    /// The command line, on this computer, that runs `executable` in the
    /// container (starting it again first if it was stopped), in
    /// `directory` there, with the variables in the file at
    /// `environmentFile` on this computer: what an agent's host runs.
    func command(in name: String, executable: String, arguments: [String], directory: String,
                 environmentFile: String) -> ShellCommand
}
