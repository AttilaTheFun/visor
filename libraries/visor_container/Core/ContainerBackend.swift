// What the container engine needs of a VM (docs/containers.md): one booted
// from a spec, processes exec'd in it, its main process waited on, and it
// stopped. VisorContainer's ContainerizationMachines on a Mac (Apple's
// Containerization: LinuxContainer, VZVirtualMachineManager); a fake in the
// tests, so the engine's lifecycle, idle stop, restart and refusals are
// tested on Linux and macOS without virtualization.

public protocol ContainerBackend: Sendable {
    /// The container made and started, its main process running.
    func boot(_ spec: ContainerBootSpec) async throws -> any ContainerMachine
}
