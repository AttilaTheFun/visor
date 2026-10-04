import Foundation

/// Tailscale Serve, through its command-line tool (on a Mac, the app's own
/// executable; elsewhere, `tailscale`). Never Funnel:
/// the identity headers that let a user's own devices in come only from
/// the tailnet, and a server that is only reachable from the tailnet is
/// one whose every caller Tailscale has named.
public final class TailscaleExposure: ServerExposure {
    public let title = "Tailscale"
    /// Where the tool is.
    let cli: String
    /// The header Serve adds to a proxied request from a tailnet user.
    static let loginHeader = "tailscale-user-login"

    public init(cli: String) {
        self.cli = cli
    }

    public var installed: Bool { FileManager.default.isExecutableFile(atPath: cli) }

    private func status() async -> [String: Any]? {
        guard installed else { return nil }
        let data = Data(await run(["status", "--json"], quiet: true).utf8)
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func trimmedName(_ name: String) -> String { name.hasSuffix(".") ? String(name.dropLast()) : name }

    /// This Mac's tailnet name ("my-mac.tail1234.ts.net").
    public func address() async -> String? {
        guard let me = await status()?["Self"] as? [String: Any], let name = me["DNSName"] as? String, !name.isEmpty else { return nil }
        return Self.trimmedName(name)
    }

    public func identity() async -> String? {
        guard let object = await status(), let me = object["Self"] as? [String: Any], let userID = me["UserID"],
              let users = object["User"] as? [String: Any], let user = users["\(userID)"] as? [String: Any],
              let login = user["LoginName"] as? String, !login.isEmpty else { return nil }
        return login
    }

    public func requester(headers: [String: String]) -> String? {
        guard let login = headers[Self.loginHeader], !login.isEmpty else { return nil }
        return login
    }

    /// Both mounts present: `/api` to the REST port, `/` to the WebSocket.
    public func fronts(port: UInt16) async -> Bool {
        guard installed else { return false }
        let text = await run(["serve", "status"], quiet: true)
        return text.contains("/api") && text.contains(String(port + 1)) && text.contains(String(port))
            && !text.lowercased().contains("funnel")
    }

    /// HTTPS on 443 in front of the server, tailnet only (declaring the
    /// paths with `serve` turns Funnel off where it was on). The tailnet
    /// needs Serve and HTTPS certificates enabled.
    @discardableResult
    public func front(port: UInt16) async -> String {
        guard installed else { return "Tailscale is not installed" }
        var output = ""
        for args in [["serve", "--tls-terminated-tcp=443", "off"],
                     ["serve", "--bg", "--https=443", "--set-path", "/api", "http://127.0.0.1:\(port + 1)"],
                     ["serve", "--bg", "--https=443", "--set-path", "/", "http://127.0.0.1:\(port)"]] {
            output += await run(args, quiet: false)
        }
        return output
    }

    /// The environment the CLI is run with. The CLI is the Tailscale
    /// app's own executable, and it acts as the command-line tool only
    /// when it looks run from a terminal (TERM, TERM_PROGRAM or SHLVL set);
    /// otherwise it tries to start the app, which is already running, and
    /// fails ("The Tailscale GUI failed to start"). A menu bar app started
    /// at login has none of them.
    static func cliEnvironment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        if environment["TERM"] == nil { environment["TERM"] = "dumb" }
        return environment
    }

    private func run(_ arguments: [String], quiet: Bool) async -> String {
        guard installed else { return "Tailscale is not installed" }
        let answer = await Command.output(cli, arguments, environment: Self.cliEnvironment(), errors: !quiet)
        return answer?.text ?? "could not run tailscale"
    }
}
