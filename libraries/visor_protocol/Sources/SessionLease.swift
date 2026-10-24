/// A machine a session leases through its server from the server's oss
/// (OS Server): what the session's row shows at its foot.
public struct SessionLease: Codable, Hashable, Sendable {
    /// oss's id for the lease.
    public var id: String
    /// What it is: "macos", "linux", "windows" (a VM), "ios" (a simulator),
    /// "android" (an emulator).
    public var platform: String
    /// Its configuration ("dev", "xcode-27.0", …), when it has one.
    public var config: String?
    /// "creating", "ready", "returning" or "failed".
    public var state: String
    /// When it runs out unless renewed: seconds since 1970.
    public var expires: Double?

    public init(id: String, platform: String, config: String? = nil, state: String, expires: Double? = nil) {
        self.id = id
        self.platform = platform
        self.config = config
        self.state = state
        self.expires = expires
    }
}
