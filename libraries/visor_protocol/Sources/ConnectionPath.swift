/// A kind of network path a connection code can lead with.
public enum ConnectionPath: String, Sendable, CaseIterable {
    case http, https, ssh

    /// Whether `address` (as a code carries it) is of this kind. A bare
    /// name is HTTPS at the root (`ServerAddress`); `user@host` is SSH.
    public func matches(_ address: String) -> Bool {
        let bare = !address.contains("://")
        return switch self {
        case .http: address.hasPrefix("http://")
        case .https: address.hasPrefix("https://") || (bare && !address.contains("@"))
        case .ssh: address.hasPrefix("ssh://") || (bare && address.contains("@"))
        }
    }

    /// What the menus call it.
    public var title: String {
        switch self {
        case .http: "HTTP"
        case .https: "HTTPS"
        case .ssh: "SSH"
        }
    }
}
