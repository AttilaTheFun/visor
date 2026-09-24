// How the server is reached from outside the Mac, and who is on the other
// end. Tailscale Serve fronts it on 443 (always; there is no other road)
// and names the tailnet user behind each request in headers the server
// trusts, so the Mac's owner needs no password. A fork that hosts sessions
// somewhere else supplies its own exposure, and the menu bar app asks it
// the same questions.

import Foundation

/// The road from clients to this server.
public protocol ServerExposure: AnyObject {
    /// What it is called in the menu ("Tailscale").
    var title: String { get }
    var installed: Bool { get }
    /// What clients type to reach the server, once fronted; nil when unknown.
    func address() -> String?
    /// The network user this machine belongs to ("logan@example.com"):
    /// whose devices are let in without a password. Nil when unknown.
    func identity() -> String?
    /// The user named by the road's own headers on a proxied request, if
    /// the road vouches for one (Tailscale Serve's identity headers).
    func requester(headers: [String: String]) -> String?
    /// Whether the server is fronted on 443 right now.
    func fronts(port: UInt16) -> Bool
    /// Puts the front in place; returns the tooling's output.
    @discardableResult func front(port: UInt16) -> String
}

/// Tailscale Serve, through the CLI inside the Mac app. Never Funnel:
/// the identity headers that let a user's own devices in come only from
/// the tailnet, and a server that is only reachable from the tailnet is
/// one whose every caller Tailscale has named.
public final class TailscaleExposure: ServerExposure {
    public let title = "Tailscale"
    static let cli = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    /// The header Serve adds to a proxied request from a tailnet user.
    static let loginHeader = "tailscale-user-login"

    public init() {}

    public var installed: Bool { FileManager.default.isExecutableFile(atPath: Self.cli) }

    private func status() -> [String: Any]? {
        guard installed else { return nil }
        let data = run(["status", "--json"], quiet: true).data(using: .utf8) ?? Data()
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func trimmedName(_ name: String) -> String { name.hasSuffix(".") ? String(name.dropLast()) : name }

    /// This Mac's tailnet name ("my-mac.tail1234.ts.net").
    public func address() -> String? {
        guard let me = status()?["Self"] as? [String: Any], let name = me["DNSName"] as? String, !name.isEmpty else { return nil }
        return Self.trimmedName(name)
    }

    public func identity() -> String? {
        guard let object = status(), let me = object["Self"] as? [String: Any], let userID = me["UserID"],
              let users = object["User"] as? [String: Any], let user = users["\(userID)"] as? [String: Any],
              let login = user["LoginName"] as? String, !login.isEmpty else { return nil }
        return login
    }

    public func requester(headers: [String: String]) -> String? {
        guard let login = headers[Self.loginHeader], !login.isEmpty else { return nil }
        return login
    }

    /// Both mounts present: `/api` to the REST port, `/` to the WebSocket.
    public func fronts(port: UInt16) -> Bool {
        guard installed else { return false }
        let text = run(["serve", "status"], quiet: true)
        return text.contains("/api") && text.contains(String(port + 1)) && text.contains(String(port))
            && !text.lowercased().contains("funnel")
    }

    /// HTTPS on 443 in front of the server, tailnet only (declaring the
    /// paths with `serve` turns Funnel off where it was on). The tailnet
    /// needs Serve and HTTPS certificates enabled.
    @discardableResult
    public func front(port: UInt16) -> String {
        guard installed else { return "Tailscale is not installed" }
        var output = ""
        for args in [["serve", "--tls-terminated-tcp=443", "off"],
                     ["serve", "--bg", "--https=443", "--set-path", "/api", "http://127.0.0.1:\(port + 1)"],
                     ["serve", "--bg", "--https=443", "--set-path", "/", "http://127.0.0.1:\(port)"]] {
            output += run(args, quiet: false)
        }
        return output
    }

    private func run(_ arguments: [String], quiet: Bool) -> String {
        guard installed else { return "Tailscale is not installed" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.cli)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = quiet ? FileHandle.nullDevice : out
        guard (try? p.run()) != nil else { return "could not run tailscale" }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return text
    }
}
