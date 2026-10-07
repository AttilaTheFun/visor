import Foundation

/// This computer, as the server tells it.
public struct HostDetails: Sendable {
    /// Its name, as a client shows it ("Logan's Mac mini").
    public var name: String
    /// Where the server keeps its sessions, pictures and settings.
    public var dataDirectory: URL
    /// This computer's addresses on its networks (IPv4, loopback left
    /// out), the most likely one first; asked when a client needs one.
    public var addresses: @Sendable () -> [String]
    /// The same, each with its interface and which network path it is;
    /// a system that names no interfaces tells them apart by range.
    public var networkAddresses: @Sendable () -> [NetworkAddress]

    public init(name: String, dataDirectory: URL, addresses: @escaping @Sendable () -> [String] = { [] },
                networkAddresses: (@Sendable () -> [NetworkAddress])? = nil) {
        self.name = name
        self.dataDirectory = dataDirectory
        self.addresses = addresses
        self.networkAddresses = networkAddresses ?? { addresses().map { NetworkAddress(address: $0) } }
    }
}
