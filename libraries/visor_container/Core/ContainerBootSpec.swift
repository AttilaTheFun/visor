// What the Sessions container boots (docs/containers.md): Kata's kernel,
// the init filesystem as `/` of the VM, the clone of the agent image's
// template as the container's root filesystem, its CPUs and memory, no
// network interface at all, the folders shared in over virtiofs, the relay's
// socket carried in, and its main process (relay-client, its way out).

import Foundation

public struct ContainerBootSpec: Equatable, Sendable {
    /// A host folder shared in over virtiofs.
    public struct Share: Equatable, Sendable {
        public var source: String
        public var destination: String
        public var readOnly: Bool

        public init(source: String, destination: String, readOnly: Bool) {
            self.source = source
            self.destination = destination
            self.readOnly = readOnly
        }
    }

    /// A Unix socket on the host carried into the guest (each connection
    /// in the guest one to the host's socket).
    public struct Socket: Equatable, Sendable {
        public var host: String
        public var guest: String

        public init(host: String, guest: String) {
            self.host = host
            self.guest = guest
        }
    }

    /// The container's id and hostname.
    public var name: String
    public var kernel: URL
    public var initfs: URL
    public var rootfs: URL
    /// The agent image (a reference by digest) and the store it's in: its
    /// environment and working folder are the processes'.
    public var image: String
    public var store: URL
    public var cpus: Int
    public var memoryBytes: UInt64
    public var shares: [Share]
    public var sockets: [Socket]
    /// The main process: relay-client, running a process that waits.
    public var arguments: [String]
    /// Its standard output and error (relay-client's lines).
    public var mainLog: URL
    /// The guest's console.
    public var bootLog: URL

    public init(name: String, kernel: URL, initfs: URL, rootfs: URL, image: String, store: URL, cpus: Int, memoryBytes: UInt64,
                shares: [Share], sockets: [Socket], arguments: [String], mainLog: URL, bootLog: URL) {
        self.name = name
        self.kernel = kernel
        self.initfs = initfs
        self.rootfs = rootfs
        self.image = image
        self.store = store
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.shares = shares
        self.sockets = sockets
        self.arguments = arguments
        self.mainLog = mainLog
        self.bootLog = bootLog
    }
}
