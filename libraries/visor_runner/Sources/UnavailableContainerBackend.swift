import Foundation

/// A container backend where containers can't be made, saying why: the
/// Runner's until Visor embeds Apple's Containerization (the shared
/// container runtime package, docs/co-tenancy.md).
public struct UnavailableContainerBackend: ContainerBackend {
    public let reason: String

    public init(reason: String = "Linux containers come with Apple's Containerization, which this build doesn't have yet") {
        self.reason = reason
    }

    public func unavailable() -> String? { reason }
    public func container(_ name: String) -> ContainerInfo? { nil }
    public func create(_ request: ContainerRequest) -> String? { reason }
    public func start(_ name: String) -> String? { reason }
    public func stop(_ name: String) -> String? { reason }
    public func remove(_ name: String, volumes: [String]) {}
    public func exec(_ name: String, _ command: [String], input: Data?) -> ContainerExec? { nil }
}
