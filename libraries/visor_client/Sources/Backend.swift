// How a client reaches a computer. The protocol is the same whatever is on
// the other end; what differs is the road — a Mac's Tailscale endpoint
// here, a company's own service hosting sandboxed sessions in a fork. A
// backend names the road and makes the transport that drives it; the
// registry is where a fork adds its own.

import VisorProtocol
import VisorServices

/// A kind of computer to connect to: its transport, and how the connect
/// form names the two things it asks for.
public protocol Backend: Sendable {
    var id: String { get }
    var title: String { get }
    var hostFieldTitle: String { get }
    var hostPlaceholder: String { get }
    var passwordFieldTitle: String { get }
    @MainActor func makeTransport() -> any HostTransport
}
