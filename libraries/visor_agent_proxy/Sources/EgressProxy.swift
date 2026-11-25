// The egress proxy (MultiPass's GitHubProxy and GitHubProxy+Forward, their
// egress alone; Logan, 2026-11-14): where a container's CONNECT and plain
// HTTP go once the relay listener has named its container. Egress stays
// open, and each connection is logged (EgressLog).
//
// A tunnel goes only where the egress policy allows (EgressPolicy): the
// internet, never an address of this Mac's own (its interfaces', loopback,
// link-local, however a name or an IPv6 form carries it), and its LAN's and
// tailnet's private ranges only where `agentProxy.egressAllow` lists them.
// A dial-in is the way to this Mac's servers. GitHub's three hosts,
// on port 443, are opened by phase 2's interceptor where there is one
// (GitHubIntercepting), and api.anthropic.com by the Anthropic one
// (Interceptors holds both); every other host, and theirs without one, is a
// plain tunnel, its bytes passed through untouched.
//
// Plain HTTP: an absolute-form request (`GET http://host/path HTTP/1.1`),
// as a program sends one to its HTTP_PROXY, forwarded to its host as an
// ordinary request and answered back, logged as a tunnel is, its body
// streamed on (at most `maxForwardedBody`). By the same policy, and never
// https (that's CONNECT's).
//
// MultiPass's own listener for native servers' agents
// (`Proxy-Authorization: Basic <server token>:<session>`) stays behind: the
// relay is the agent proxy's only way in.

import CAgentProxyPOSIX
import Foundation

/// Tunnels and plain HTTP for containers' agents, each connection logged.
public final class EgressProxy: Sendable {
    /// Who asked: the container, by its lease, and the agent if the request
    /// named one.
    public struct Caller: Equatable, Sendable {
        public var lease: String
        public var agent: String?

        public init(lease: String, agent: String? = nil) {
            self.lease = lease
            self.agent = agent
        }

        /// As the log lines name it: `container:<lease>`.
        public var session: String { "container:\(lease)" }
    }

    /// Where a `CONNECT` asks to go.
    public struct Destination: Equatable, Sendable {
        public var host: String
        public var port: UInt16

        public init(host: String, port: UInt16) {
            self.host = host
            self.port = port
        }
    }

    let connect: @Sendable (Destination) -> Int32
    let log: @Sendable (String) -> Void
    private let interceptor: (any GitHubIntercepting)?
    /// Where each connection is logged (none: the lines of `log` alone).
    let egress: EgressLog?

    /// The largest body an absolute-form request may have (16 MB): one
    /// larger is refused (413).
    public static let maxForwardedBody = 16 << 20

    /// `policy`: where the destination may be (the internet alone unless it
    /// lists more). `connect`: the way to the destination, in place of the
    /// policy's, for a test. `interceptor`: what opens GitHub's hosts
    /// (phase 2's; none: they are tunnels too). `egress`: the egress log.
    public init(policy: EgressPolicy = EgressPolicy(), connect: (@Sendable (Destination) -> Int32)? = nil,
                interceptor: (any GitHubIntercepting)? = nil, egress: EgressLog? = nil, log: @escaping @Sendable (String) -> Void) {
        agent_proxy_ignore_broken_pipes()
        self.connect = connect ?? { policy.connect($0) }
        self.interceptor = interceptor
        self.egress = egress
        self.log = log
    }

    /// `destination`, as it went for `caller`, in the egress log.
    func record(_ caller: Caller, _ destination: Destination, _ outcome: EgressLog.Outcome) {
        let route: EgressLog.Route = GitHubHosts.contains(destination.host) ? .github
            : destination.host.lowercased() == AnthropicInterceptor.host ? .anthropic : .egress
        egress?.record(EgressLog.Entry(host: destination.host.lowercased(), port: Int(destination.port), lease: caller.lease,
                                       agentClaimed: caller.agent, route: route, outcome: outcome))
    }

    /// A `CONNECT` from a caller the relay named: GitHub's hosts opened by
    /// the interceptor where there is one, any other a tunnel off this
    /// computer.
    func tunnel(_ client: Int32, _ request: HTTPRequest, to destination: Destination, caller: Caller) {
        if let interceptor, interceptor.intercepts(destination) {
            log("\(caller.session) CONNECT \(destination.host):\(destination.port) opened")
            record(caller, destination, .opened)
            HTTPRequest.send(client, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
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
            log("\(caller.session) CONNECT \(destination.host):\(destination.port) \(refused ? "refused: not the internet's" : Self.unreachable())")
            record(caller, destination, refused ? .refused : .unreachable)
            HTTPRequest.reply(client, refused ? "403 Forbidden" : "502 Bad Gateway",
                              refused ? "Refused: \(destination.host) is this computer's, or its network's." : "\(destination.host) can't be reached.")
            close(client)
            return
        }
        log("\(caller.session) CONNECT \(destination.host):\(destination.port) tunnel")
        record(caller, destination, .tunnelled)
        HTTPRequest.send(client, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
        // A tunnel may be quiet for as long as it likes (the head's wait is over).
        agent_proxy_set_receive_timeout(client, 0)
        // What the client sent after its CONNECT (its TLS hello, already).
        if !request.body.isEmpty { HTTPRequest.send(server, request.body) }
        Splice.join(client, server)
    }

    /// Forwards `request` (absolute-form, plain HTTP) for `caller`: the
    /// request line made origin-form, the proxy's own headers dropped, the
    /// connection closed after the answer.
    func forward(_ client: Int32, _ request: HTTPRequest, caller: Caller) {
        guard let (destination, path) = Self.absolute(request.path) else {
            HTTPRequest.reply(client, "400 Bad Request", "An absolute http:// URL is forwarded; https goes by CONNECT.")
            close(client)
            return
        }
        guard request.contentLength <= Self.maxForwardedBody else {
            log("\(caller.session) \(request.method) \(destination.host):\(destination.port) refused: a body of \(request.contentLength) bytes")
            record(caller, destination, .refused)
            HTTPRequest.reply(client, "413 Content Too Large", "A body of at most \(Self.maxForwardedBody) bytes is forwarded.")
            close(client)
            return
        }
        let server = connect(destination)
        guard server >= 0 else {
            let refused = errno == EACCES
            log("\(caller.session) \(request.method) \(destination.host):\(destination.port) \(refused ? "refused: not the internet's" : Self.unreachable())")
            record(caller, destination, refused ? .refused : .unreachable)
            HTTPRequest.reply(client, refused ? "403 Forbidden" : "502 Bad Gateway",
                              refused ? "Refused: \(destination.host) is this computer's, or its network's." : "\(destination.host) can't be reached.")
            close(client)
            return
        }
        log("\(caller.session) \(request.method) \(destination.host):\(destination.port) forwarded")
        record(caller, destination, .forwarded)
        let dropped: Set<String> = ["proxy-authorization", "proxy-connection", "connection", "keep-alive"]
        var head = "\(request.method) \(path) HTTP/1.1\r\n"
        for header in request.headers where !dropped.contains(header.name.lowercased()) {
            head += "\(header.name): \(header.value)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        // Not half-closed after: a server may take that as the client gone
        // and close without answering (CDNs do). The request is whole by its
        // length, and `Connection: close` ends the answer.
        HTTPRequest.send(server, Data(head.utf8) + request.body)
        // The rest of the body, as it comes, never held whole.
        if request.unreadBody > 0, !HTTPRequest.copy(request.unreadBody, from: client, to: server) {
            close(server)
            close(client)
            return
        }
        Splice.pump(from: server, to: client)
        close(server)
        close(client)
    }

    /// What the log says of a destination that couldn't be reached, read
    /// right after the connection failed (on its thread): where it was a
    /// private address `egressAllow` lets through and the system said no
    /// route (or no permission), the Local Network permission's absence on
    /// macOS, which a launchd job can't be asked for.
    static func unreachable(privateFailure: Bool = agent_proxy_last_failure_private() == 1) -> String {
        privateFailure ? "unreachable: \(localNetworkHint)" : "unreachable"
    }

    /// The Local Network permission, said plainly: agent-proxy is Shireworks
    /// (its bundle id), so the app's permission is the one it needs.
    public static let localNetworkHint = "Local Network permission: grant Shireworks it once "
        + "(System Settings › Privacy & Security › Local Network), for agent-proxy's egress to the LAN egressAllow lists"

    /// A `CONNECT`'s target: `host:port`, or `[v6]:port`.
    static func destination(_ target: String) -> Destination? {
        guard let colon = target.lastIndex(of: ":"), let port = UInt16(target[target.index(after: colon)...]), port > 0 else { return nil }
        var host = String(target[..<colon])
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "@" }) else { return nil }
        return Destination(host: host, port: port)
    }

    /// An absolute-form target's host, port and path: `http://host[:port]/path`.
    static func absolute(_ target: String) -> (destination: Destination, path: String)? {
        guard target.lowercased().hasPrefix("http://") else { return nil }
        let rest = target.dropFirst("http://".count)
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        let authority = String(rest[..<slash])
        let path = slash == rest.endIndex ? "/" : String(rest[slash...])
        guard !authority.isEmpty, !authority.contains("@") else { return nil }
        if let destination = destination(authority) { return (destination, path) }
        var host = authority
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        return (Destination(host: host, port: 80), path)
    }

    /// The agent a request names: its `X-Agent-ID` (`<uuid>`, or
    /// `<uuid>@<dispatcher>`), as a lower-case UUID; nil when it names none.
    static func agent(in request: HTTPRequest) -> String? {
        guard let value = request.headers.first(where: { $0.name.lowercased() == "x-agent-id" })?.value else { return nil }
        let id = String(value.split(separator: "@").first ?? "").trimmingCharacters(in: .whitespaces)
        return UUID(uuidString: id) != nil ? id.lowercased() : nil
    }
}
