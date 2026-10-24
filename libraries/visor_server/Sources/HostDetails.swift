import Foundation

/// This computer, as the server tells it.
public struct HostDetails: Sendable {
    /// Its name, as a client shows it ("Studio Mac").
    public var name: String
    /// The system: "macos", "linux" or "windows" (what a session's row
    /// shows its agent runs on, when not in a container).
    public var system: String
    /// The server's own version and build, as installed and running
    /// ("0.31 (8)"); empty where the binary does not say.
    public var version: String
    /// Where the server keeps its sessions, pictures and settings.
    public var dataDirectory: URL
    /// This computer's addresses on its networks (IPv4, loopback left
    /// out), the most likely one first; asked when a client needs one.
    public var addresses: @Sendable () -> [String]
    /// The same, each with its interface and which network path it is;
    /// a system that names no interfaces tells them apart by range.
    public var networkAddresses: @Sendable () -> [NetworkAddress]
    /// This computer's name on its local network, as multicast DNS answers
    /// it ("Studio-Mac.local"): the same when the network gives it another
    /// address. Nil where the system names none.
    public var localNetworkName: @Sendable () -> String?
    /// A name's IPv4 address as this computer resolves it, for those who
    /// cannot (an agent in a container resolves no `.local` names); nil
    /// where it cannot be.
    public var resolve: @Sendable (String) -> String?

    public init(name: String, system: String = "", version: String = "", dataDirectory: URL, addresses: @escaping @Sendable () -> [String] = { [] },
                networkAddresses: (@Sendable () -> [NetworkAddress])? = nil,
                localNetworkName: @escaping @Sendable () -> String? = { nil },
                resolve: @escaping @Sendable (String) -> String? = { _ in nil }) {
        self.localNetworkName = localNetworkName
        self.resolve = resolve
        self.name = name
        self.system = system
        self.version = version
        self.dataDirectory = dataDirectory
        self.addresses = addresses
        let given = networkAddresses ?? { addresses().map { NetworkAddress(address: $0) } }
        self.networkAddresses = { given().filter { !NetworkAddress.isLinkLocal($0.address) && !NetworkAddress.isLoopback($0.address) } }
    }
}
