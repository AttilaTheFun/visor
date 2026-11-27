/// What a client changes of a server's own settings (`PUT /api/settings`):
/// each field set is changed, the rest left as they are. Its owner's
/// Settings sends one field at a time, as each is edited.
public struct ServerControlsChange: Equatable, Sendable {
    /// A new password (never empty: one can't be taken away).
    public var password: String?
    public var authentication: String?
    public var lan: Bool?
    public var vpn: Bool?
    public var sshEnabled: Bool?
    public var proxyEnabled: Bool?
    public var publicAddress: String?
    public var tlsIdentityPath: String?
    /// The TLS identity's password, kept with the secrets: the server
    /// listens again with it.
    public var tlsPassword: String?
    public var detachAgents: Bool?
    public var clientsKeepMessages: Bool?
    /// The Sessions container on or off (ContainerSettings.enabled).
    public var containerEnabled: Bool?
    /// Its CPUs and memory cap in GiB (ContainerSettings.cpus, .memoryGiB):
    /// taken at its next start, never by restarting it. Within this
    /// computer's (docs/containers.md, Settings), or refused.
    public var containerCPUs: Amount?
    public var containerMemoryGiB: Amount?
    /// Minutes with nothing in it before it's stopped
    /// (ContainerSettings.idleMinutes): taken at once.
    public var containerIdleMinutes: Amount?

    /// A number of the container's, changed: set, or back to its default
    /// (`null` or `"default"` in JSON). Anything else (a word, a fraction)
    /// is kept as it came, for the server to refuse.
    public enum Amount: Equatable, Sendable {
        case to(Int)
        case byDefault
        case unreadable(JSONValue)
    }

    public init(password: String? = nil, authentication: String? = nil, lan: Bool? = nil, vpn: Bool? = nil, sshEnabled: Bool? = nil,
                proxyEnabled: Bool? = nil, publicAddress: String? = nil, tlsIdentityPath: String? = nil, tlsPassword: String? = nil,
                detachAgents: Bool? = nil, clientsKeepMessages: Bool? = nil, containerEnabled: Bool? = nil, containerCPUs: Amount? = nil,
                containerMemoryGiB: Amount? = nil, containerIdleMinutes: Amount? = nil) {
        self.password = password
        self.authentication = authentication
        self.lan = lan
        self.vpn = vpn
        self.sshEnabled = sshEnabled
        self.proxyEnabled = proxyEnabled
        self.publicAddress = publicAddress
        self.tlsIdentityPath = tlsIdentityPath
        self.tlsPassword = tlsPassword
        self.detachAgents = detachAgents
        self.clientsKeepMessages = clientsKeepMessages
        self.containerEnabled = containerEnabled
        self.containerCPUs = containerCPUs
        self.containerMemoryGiB = containerMemoryGiB
        self.containerIdleMinutes = containerIdleMinutes
    }
}
