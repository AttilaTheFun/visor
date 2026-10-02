import VisorProtocol
import VisorServices

/// A Mac running the menu bar app behind its Tailscale Serve endpoint:
/// wss:// on 443 for the live channel, https://…/api for calls, the
/// password as a bearer token.
public struct TailscaleBackend: Backend {
    public let id = "tailscale"
    public let title = "Tailscale"
    public let hostFieldTitle = "Tailscale name"
    public let hostPlaceholder = "my-mac.tail1234.ts.net"
    public let passwordFieldTitle = "Password (if asked)"
    public init() {}
    public func makeTransport() -> any HostTransport { TailscaleTransport() }
}
