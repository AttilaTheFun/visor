import Foundation

/// This computer, as the server tells it.
public struct HostDetails: Sendable {
    /// Its name, as a client shows it ("Logan's Mac mini").
    public var name: String
    /// Where the server keeps its sessions, pictures and settings.
    public var dataDirectory: URL
    /// This computer's addresses on its networks (IPv4, loopback left
    /// out), the most likely road first; asked when a client needs one.
    public var addresses: @Sendable () -> [String]

    public init(name: String, dataDirectory: URL, addresses: @escaping @Sendable () -> [String] = { [] }) {
        self.name = name
        self.dataDirectory = dataDirectory
        self.addresses = addresses
    }
}
