import CVisorPOSIX
import Foundation

/// The Runner's GitHub proxy (docs/github-proxy.md): an HTTP `CONNECT`
/// proxy, which each Visor server's agents reach through `HTTPS_PROXY`, with
/// `Proxy-Authorization: Basic <server token>:<session id>[@<owner>/<name>]`.
/// The server token is one the Runner gave a server it serves (ProxyTokens,
/// as the MCP proxy checks it); the session id and its repository (the
/// session folder's, `$SESSION_REPOSITORY`) are the server's word, for the
/// logs and the session's tokens.
///
/// A tunnel goes only to an address off this computer
/// (`visor_connect_tcp_public`), so no name leads an agent, a container's
/// included, back to the Mac's own services. GitHub's three hosts, on port
/// 443, are opened by the interceptor (GitHubInterceptor: GitHubGate's
/// rules, the session's token); every other host is a plain tunnel, its
/// bytes passed through untouched.
public final class GitHubProxy: Sendable {
    /// Who asked: the server's token, and the session it says the agent is.
    public struct Caller: Equatable, Sendable {
        public var token: String
        public var session: String
        /// The session's own repository, `owner/name`: whose token a read
        /// that names none (a GraphQL query, a search) goes with.
        public var repository: String?
    }

    /// Where a `CONNECT` asks to go.
    public struct Destination: Equatable, Sendable {
        public var host: String
        public var port: UInt16
    }

    private let listeners: [Int32]
    private let admits: @Sendable (String) -> Bool
    private let connect: @Sendable (Destination) -> Int32
    private let log: @Sendable (String) -> Void
    private let interceptor: GitHubInterceptor?

    /// Listening at `port`, IPv4 and IPv6 (either is enough). Nil when
    /// neither can be had. `connect` is the way to the destination: off
    /// this computer only, unless a test says otherwise.
    /// `interceptor`: what opens GitHub's hosts (nil: they are tunnels too).
    init?(port: Int, admits: @escaping @Sendable (String) -> Bool,
          connect: @escaping @Sendable (Destination) -> Int32 = { visor_connect_tcp_public($0.host, $0.port) },
          interceptor: GitHubInterceptor? = nil, log: @escaping @Sendable (String) -> Void) {
        guard (1...65535).contains(port) else { return nil }
        visor_ignore_broken_pipes()
        listeners = [visor_listen(UInt16(port), 1), visor_listen6(UInt16(port))].filter { $0 >= 0 }
        guard !listeners.isEmpty else { return nil }
        self.admits = admits
        self.connect = connect
        self.interceptor = interceptor
        self.log = log
    }

    /// Every host a tunnel, GitHub's too.
    public convenience init?(port: Int, admits: @escaping @Sendable (String) -> Bool, log: @escaping @Sendable (String) -> Void) {
        self.init(port: port, admits: admits, interceptor: nil, log: log)
    }

    /// The Runner's: GitHub's hosts opened with the Runner's authority and
    /// GitHubGate's rules, each session's tokens from Keymaster.
    public convenience init?(port: Int, admits: @escaping @Sendable (String) -> Bool, ca: RunnerCA, rules: GateRules = .standard,
                             keymaster: URL, app: String, key: @escaping @Sendable () -> String?,
                             log: @escaping @Sendable (String) -> Void) {
        let tokens = KeymasterTokens(url: keymaster, app: app, key: key)
        guard let interceptor = try? GitHubInterceptor(gate: GitHubGate(rules: rules), ca: ca, tokens: tokens, log: log) else { return nil }
        self.init(port: port, admits: admits, interceptor: interceptor, log: log)
    }

    public func start() {
        for listener in listeners {
            Thread.detachNewThread { [self] in
                while true {
                    let client = visor_accept(listener)
                    if client < 0 { return }
                    Thread.detachNewThread { [self] in serve(client) }
                }
            }
        }
    }

    public func stop() {
        for listener in listeners {
            visor_shutdown(listener)
            close(listener)
        }
        interceptor?.stop()
    }

    /// One client: its `CONNECT` checked, then the tunnel, both ways, until
    /// both have ended.
    private func serve(_ client: Int32) {
        guard let request = MCPProxy.read(client) else {
            close(client)
            return
        }
        guard request.method == "CONNECT", let destination = Self.destination(request.path) else {
            MCPProxy.reply(client, "405 Method Not Allowed", "Visor's GitHub proxy takes CONNECT host:port alone.")
            close(client)
            return
        }
        guard let caller = Self.caller(request.header("Proxy-Authorization")), admits(caller.token) else {
            MCPProxy.send(client, Data(("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"Visor\"\r\n"
                + "Content-Length: 0\r\nConnection: close\r\n\r\n").utf8))
            close(client)
            return
        }
        if let interceptor, destination.port == 443, GitHubGate.hosts.contains(destination.host.lowercased()) {
            log("\(caller.session) CONNECT \(destination.host):443 opened")
            MCPProxy.send(client, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
            // What came after the CONNECT, already: its TLS hello. A client
            // waits for the answer first, as git, gh and curl do.
            guard request.body.isEmpty else {
                close(client)
                return
            }
            interceptor.adopt(client, host: destination.host.lowercased(), caller: caller)
            return
        }
        let server = connect(destination)
        guard server >= 0 else {
            let refused = errno == EACCES
            log("\(caller.session) CONNECT \(destination.host):\(destination.port) \(refused ? "refused: this computer's" : "unreachable")")
            MCPProxy.reply(client, refused ? "403 Forbidden" : "502 Bad Gateway",
                           refused ? "Refused: \(destination.host) is this computer's." : "\(destination.host) can't be reached.")
            close(client)
            return
        }
        log("\(caller.session) CONNECT \(destination.host):\(destination.port) tunnel")
        MCPProxy.send(client, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
        // What the client sent after its CONNECT (its TLS hello, already).
        if !request.body.isEmpty { MCPProxy.send(server, request.body) }
        let ended = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            ClientProxy.pump(from: client, to: server)
            ended.signal()
        }
        Thread.detachNewThread {
            ClientProxy.pump(from: server, to: client)
            ended.signal()
        }
        ended.wait()
        if ended.wait(timeout: .now() + 5) == .timedOut {
            visor_shutdown(client)
            visor_shutdown(server)
            ended.wait()
        }
        close(client)
        close(server)
    }

    /// A `CONNECT`'s target: `host:port`, or `[v6]:port`.
    static func destination(_ target: String) -> Destination? {
        guard let colon = target.lastIndex(of: ":"), let port = UInt16(target[target.index(after: colon)...]), port > 0 else { return nil }
        var host = String(target[..<colon])
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "@" }) else { return nil }
        return Destination(host: host, port: port)
    }

    /// The caller a `Proxy-Authorization: Basic …` names: the server's token,
    /// a colon, the session's id (which has none).
    static func caller(_ authorization: String?) -> Caller? {
        guard let authorization, authorization.lowercased().hasPrefix("basic "),
              let decoded = Data(base64Encoded: String(authorization.dropFirst(6)).trimmingCharacters(in: .whitespaces)),
              let text = String(data: decoded, encoding: .utf8), let colon = text.lastIndex(of: ":") else { return nil }
        let token = String(text[..<colon])
        var session = String(text[text.index(after: colon)...])
        var repository: String?
        if let at = session.firstIndex(of: "@") {
            repository = String(session[session.index(after: at)...])
            session = String(session[..<at])
            guard let named = repository, named.split(separator: "/").count == 2 else { return nil }
        }
        guard !token.isEmpty, !session.isEmpty else { return nil }
        return Caller(token: token, session: session, repository: repository)
    }
}
