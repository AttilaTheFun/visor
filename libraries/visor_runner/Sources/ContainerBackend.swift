import Foundation

/// What makes and runs the Runner's containers (docs/co-tenancy.md): Apple's
/// Containerization in the app's bundle, a helper process per container on
/// one network of the Runner's; faked by the tests. Its calls take time
/// (a VM booted, an image unpacked): make them off the main thread. A
/// method that can fail answers nil, or what went wrong.
public protocol ContainerBackend: Sendable {
    /// Nil when containers can be made here, else why not.
    func unavailable() -> String?
    /// The container named `name` as it is now; nil when there is none.
    func container(_ name: String) -> ContainerInfo?
    /// A new container made and started from `request`, its volumes made
    /// where they aren't and kept where they are.
    func create(_ request: ContainerRequest) -> String?
    func start(_ name: String) -> String?
    func stop(_ name: String) -> String?
    /// The container gone, and the volumes named with it.
    func remove(_ name: String, volumes: [String])
    /// `command` run in the container to its end, `input` its standard
    /// input; nil when it couldn't be run.
    func exec(_ name: String, _ command: [String], input: Data?) -> ContainerExec?
}
