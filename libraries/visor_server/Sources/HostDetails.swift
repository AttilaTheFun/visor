import Foundation

/// This computer, as the server tells it.
public struct HostDetails: Sendable {
    /// Its name, as a client shows it ("Studio Mac").
    public var name: String
    /// The system: "macos", "linux" or "windows" (what a session's row
    /// shows its agent runs on, when not in a container).
    public var system: String
    /// Whether the server itself runs in a container, its agents with it
    /// (a co-tenant container): its sessions say so (`SessionInfo.inContainer`).
    public var inContainer: Bool
    /// The server's own version and build, as installed and running
    /// ("0.31 (8)"); empty where the binary does not say.
    public var version: String
    /// Where the server keeps its sessions, pictures and settings.
    public var dataDirectory: URL
    /// Visor's own Linux programs, for the containers the server makes
    /// (docs/co-tenancy.md, "Container images"): a folder of this
    /// computer's holding `visor-server` and `visor-agent-host` built for
    /// Linux, mounted read-only at `ContainerPlacement.programsFolder` in
    /// each, so a container needs nothing of Visor's in its image. Nil
    /// where the binary carries none (a build without them).
    public var containerPrograms: URL?
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
    /// In a container, the folders its computer shares with it, each at its
    /// own path (the Mac's ~/Developer at /Users/<name>/Developer): a
    /// session moved here works under one of them, or it would land on the
    /// container's own disk, which nothing else sees (VisorServer+
    /// MigrationArrival). Nil where the server's disk is its computer's own,
    /// or the container's shares can't be told.
    public var sharedFolders: @Sendable () -> [String]?

    public init(name: String, system: String = "", inContainer: Bool = false, version: String = "", dataDirectory: URL,
                containerPrograms: URL? = nil,
                addresses: @escaping @Sendable () -> [String] = { [] },
                networkAddresses: (@Sendable () -> [NetworkAddress])? = nil,
                localNetworkName: @escaping @Sendable () -> String? = { nil },
                resolve: @escaping @Sendable (String) -> String? = { _ in nil },
                sharedFolders: @escaping @Sendable () -> [String]? = { nil }) {
        self.sharedFolders = sharedFolders
        self.localNetworkName = localNetworkName
        self.resolve = resolve
        self.name = name
        self.system = system
        self.inContainer = inContainer
        self.version = version
        self.dataDirectory = dataDirectory
        self.containerPrograms = containerPrograms
        self.addresses = addresses
        let given = networkAddresses ?? { addresses().map { NetworkAddress(address: $0) } }
        self.networkAddresses = { given().filter { !NetworkAddress.isLinkLocal($0.address) && !NetworkAddress.isLoopback($0.address) } }
    }
}
