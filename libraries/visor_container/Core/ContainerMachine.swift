// A container the backend booted (ContainerBackend).

public protocol ContainerMachine: Sendable {
    /// A process started in it, its output to `process.log`.
    func exec(_ process: ContainerProcessSpec) async throws -> any ContainerMachineProcess
    /// Its main process's status, once it has ended (the container stopped,
    /// or the process died).
    func waitMain() async -> Int32
    /// Stopped: every process in it ended, the VM gone.
    func stop() async
}
