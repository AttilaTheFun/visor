import Foundation

/// What a container host is asked to make (`create`,
/// docs/container-host.md): from an image, of a size, with this computer's
/// folders and disks of its own.
struct ContainerHostRequest: Codable, Equatable, Sendable {
    var api = ContainerHost.api
    var name: String
    var image: String
    var cpus: Int
    var memoryBytes: Int64
    var mounts: [Mount]
    var volumes: [Volume]
    var environment: [String: String] = [:]
    var rosetta = true
    var labels: [String: String] = [:]

    /// One of this computer's folders, seen in the container at `destination`.
    struct Mount: Codable, Equatable, Sendable {
        var source: String
        var destination: String
        var readOnly = false
    }

    /// A disk of the container's own, kept by its name until removed with it.
    struct Volume: Codable, Equatable, Sendable {
        var name: String
        var destination: String
        var sizeBytes: Int64
    }
}
