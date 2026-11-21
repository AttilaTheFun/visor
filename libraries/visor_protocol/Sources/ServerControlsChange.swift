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

    public init(password: String? = nil, authentication: String? = nil, lan: Bool? = nil, vpn: Bool? = nil, sshEnabled: Bool? = nil,
                proxyEnabled: Bool? = nil, publicAddress: String? = nil, tlsIdentityPath: String? = nil, tlsPassword: String? = nil,
                detachAgents: Bool? = nil, clientsKeepMessages: Bool? = nil, containerEnabled: Bool? = nil) {
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
    }
}
