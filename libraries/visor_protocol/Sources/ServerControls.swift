/// A server as its owner's menu and Settings show it (`GET /api/settings`):
/// how it is reached and signed in to, what it is doing, and the settings
/// those change (`PUT /api/settings`, ServerControlsChange). Visor on the
/// Mac reads its own server's this way, whichever process runs it.
public struct ServerControls: Equatable, Sendable {
    /// The settings a change sets (ServerSettings' own, as the server keeps
    /// them).
    public struct Settings: Equatable, Sendable {
        /// "password", or "none": what a client shows to sign in.
        public var authentication: String
        public var lan: Bool
        public var vpn: Bool
        /// SSH clients let in at the socket file without a password.
        public var sshEnabled: Bool
        public var proxyEnabled: Bool
        public var publicAddress: String
        public var tlsIdentityPath: String
        public var detachAgents: Bool
        public var clientsKeepMessages: Bool
        /// The Sessions container's setting (ContainerSettings.enabled): on
        /// only where the Mac can run it, which Settings decides.
        public var containerEnabled: Bool
        /// Its image digest in place of the release's (`sha256:…`); empty
        /// for the release's. Set in the server's settings file.
        public var containerImageDigest: String
        /// Its CPUs and memory cap in GiB as set; nil for the defaults
        /// (`containerLimits` says what they are). Taken at its next start.
        public var containerCPUs: Int?
        public var containerMemoryGiB: Int?
        /// Minutes with nothing in it before it's stopped.
        public var containerIdleMinutes: Int

        public init(authentication: String = "password", lan: Bool = false, vpn: Bool = false, sshEnabled: Bool = true,
                    proxyEnabled: Bool = false, publicAddress: String = "", tlsIdentityPath: String = "", detachAgents: Bool = true,
                    clientsKeepMessages: Bool = true, containerEnabled: Bool = false, containerImageDigest: String = "",
                    containerCPUs: Int? = nil, containerMemoryGiB: Int? = nil, containerIdleMinutes: Int = 30) {
            self.authentication = authentication
            self.lan = lan
            self.vpn = vpn
            self.sshEnabled = sshEnabled
            self.proxyEnabled = proxyEnabled
            self.publicAddress = publicAddress
            self.tlsIdentityPath = tlsIdentityPath
            self.detachAgents = detachAgents
            self.clientsKeepMessages = clientsKeepMessages
            self.containerEnabled = containerEnabled
            self.containerImageDigest = containerImageDigest
            self.containerCPUs = containerCPUs
            self.containerMemoryGiB = containerMemoryGiB
            self.containerIdleMinutes = containerIdleMinutes
        }

        /// Anyone who reaches the server is let in.
        public var asksNothing: Bool { authentication == "none" }
    }

    /// What the Sessions container's CPUs, memory and idle minutes may be
    /// set to on this computer (docs/containers.md, Settings), and their
    /// defaults: a value outside them is refused, never clamped.
    public struct ContainerLimits: Equatable, Sendable {
        /// At least one CPU, at most this computer's cores; eight by
        /// default, leaving two of them.
        public var minimumCPUs: Int
        public var maximumCPUs: Int
        public var defaultCPUs: Int
        /// At least 4 GiB, at most all of this computer's less 4; by default
        /// half of what's free when it starts, within 4 and 24.
        public var minimumMemoryGiB: Int
        public var maximumMemoryGiB: Int
        public var defaultMemoryCapGiB: Int
        public var minimumIdleMinutes: Int
        public var maximumIdleMinutes: Int
        public var defaultIdleMinutes: Int
        /// When a change takes effect, said for a person.
        public var note: String

        public init(minimumCPUs: Int = 1, maximumCPUs: Int, defaultCPUs: Int, minimumMemoryGiB: Int = 4, maximumMemoryGiB: Int,
                    defaultMemoryCapGiB: Int = 24, minimumIdleMinutes: Int = 1, maximumIdleMinutes: Int = 1440,
                    defaultIdleMinutes: Int = 30, note: String = "") {
            self.minimumCPUs = minimumCPUs
            self.maximumCPUs = maximumCPUs
            self.defaultCPUs = defaultCPUs
            self.minimumMemoryGiB = minimumMemoryGiB
            self.maximumMemoryGiB = maximumMemoryGiB
            self.defaultMemoryCapGiB = defaultMemoryCapGiB
            self.minimumIdleMinutes = minimumIdleMinutes
            self.maximumIdleMinutes = maximumIdleMinutes
            self.defaultIdleMinutes = defaultIdleMinutes
            self.note = note
        }
    }

    /// The computer's name, the server's id and version.
    public var host = ""
    public var id = ""
    public var version = ""
    /// The port it serves on (7433).
    public var port = 7433
    /// What every client signs in with; empty until one is set.
    public var password = ""
    /// Whether it listens on its port.
    public var listening = false
    /// Why it couldn't, last time.
    public var lastError: String?
    /// An update that didn't stay up and was rolled back.
    public var updateNotice: String?
    /// The address clients are told; nil when only this computer and SSH
    /// reach it.
    public var reachableAddress: String?
    /// Its connection codes, once it has a password and an address.
    public var codes: ConnectionCodes?
    /// The clients connected to its live channel.
    public var clientCount = 0
    /// Whether it serves TLS itself (the identity set is read).
    public var servesTLS = false
    /// `ssh://user@address` for each of this computer's addresses, while
    /// SSH clients are let in.
    public var sshPaths: [String] = []
    public var settings = Settings()
    /// Whether agents run apart from it as its environment sets it
    /// (VISOR_DETACH_AGENT_HOST); nil when that is left to the setting.
    public var detachingSet: Bool?
    /// The APNs key's ids, and whether all of it is set.
    public var apnsKeyID = ""
    public var apnsTeamID = ""
    public var apnsConfigured = false
    /// The devices that asked for notifications.
    public var pushDevices = 0
    /// Whether there is an admin token.
    public var hasAdminToken = false
    /// What the container's CPUs, memory and idle minutes may be set to
    /// here; nil from a server that doesn't say (before 0.73).
    public var containerLimits: ContainerLimits?

    public init() {}

    /// Whether it serves: a password set, or nothing asked.
    public var hasPassword: Bool { !password.isEmpty || settings.asksNothing }
}
