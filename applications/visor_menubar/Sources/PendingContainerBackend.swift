import Foundation
import VisorRunner

/// The container backend until Visor embeds Apple's Containerization (the
/// shared container runtime package, docs/co-tenancy.md): containers can't
/// be made yet, and it says so.
struct PendingContainerBackend: ContainerBackend {
    func unavailable() -> String? { "Linux containers come with Apple's Containerization, which this build doesn't have yet" }
    func container(_ name: String) -> ContainerInfo? { nil }
    func create(_ request: ContainerRequest) -> String? { unavailable() }
    func start(_ name: String) -> String? { unavailable() }
    func stop(_ name: String) -> String? { unavailable() }
    func remove(_ name: String, volumes: [String]) {}
    func exec(_ name: String, _ command: [String], input: Data?) -> ContainerExec? { nil }
}
