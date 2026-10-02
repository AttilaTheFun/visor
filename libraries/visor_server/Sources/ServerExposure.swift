// How the server is reached from outside the Mac, and who is on the other
// end. Tailscale Serve fronts it on 443 (always; there is no other road)
// and names the tailnet user behind each request in headers the server
// trusts, so the Mac's owner needs no password. A fork that hosts sessions
// somewhere else supplies its own exposure, and the menu bar app asks it
// the same questions.

import Foundation

/// The road from clients to this server. What it knows it finds out by
/// asking its tooling, which takes a while: the server asks from time to
/// time and keeps the answers (`VisorServer.address`, `hostLogin`).
public protocol ServerExposure: AnyObject, Sendable {
    /// What it is called in the menu ("Tailscale").
    var title: String { get }
    var installed: Bool { get }
    /// What clients type to reach the server, once fronted; nil when unknown.
    func address() async -> String?
    /// The network user this machine belongs to ("logan@example.com"):
    /// whose devices are let in without a password. Nil when unknown.
    func identity() async -> String?
    /// The user named by the road's own headers on a proxied request, if
    /// the road vouches for one (Tailscale Serve's identity headers).
    func requester(headers: [String: String]) -> String?
    /// Whether the server is fronted on 443 right now.
    func fronts(port: UInt16) async -> Bool
    /// Puts the front in place; returns the tooling's output.
    @discardableResult func front(port: UInt16) async -> String
}
