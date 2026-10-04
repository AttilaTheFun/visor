import Foundation

/// This computer, as the server tells it.
public struct HostDetails: Sendable {
    /// Its name, as a client shows it ("Logan's Mac mini").
    public var name: String
    /// Where the server keeps its sessions, pictures and settings.
    public var dataDirectory: URL

    public init(name: String, dataDirectory: URL) {
        self.name = name
        self.dataDirectory = dataDirectory
    }
}
