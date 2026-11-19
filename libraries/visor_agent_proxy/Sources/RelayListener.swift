// Where the relay brings each container's streams (Visor's
// docs/server-proxy.md, "Containers: no network"; docs/agent-proxy.md): a
// listener on this computer's loopback alone. Each stream starts with the
// relay's PROXY v2 header (ProxyProtocolHeader); one without the relay's
// token, or the relay's own LOCAL, is closed unanswered. What follows is the
// container's request, taken as that container's: a CONNECT (tunnelled, or
// intercepted for GitHub by the interceptor, GitHubInterceptor) or an
// absolute http:// request (forwarded), through the egress proxy
// (EgressProxy); or `POST /dns-query`, DNS over HTTPS's wire form (RFC
// 8484), answered by the agent proxy's resolver; or `/mcp/<name>`, answered
// by what the listener is given (MCPAnswering; 404 without one). The
// dial-ins come first: a CONNECT to one of the agent proxy's own names
// (`<name>.agent.internal`); a plain request to one of its names is
// refused, never looked up. Every CONNECT and absolute request is logged
// (EgressLog). `GET /` answers 200, for a container's health probe. A lease
// id is letters, digits and hyphens; the header has 2 seconds in all, and
// the request's head 10; the streams at once are capped (ConnectionCaps: 64
// of them still reading their header), and the listener's own bodies at 64
// KB. Moved from MultiPass's RelayListener (Logan, 2026-11-14), then into
// Visor from Shireworks' v0.15.1 (19 Nov 2026), without Shireworks' own
// routes (the `shireworks.agent.internal` forward and `/mcp/shireworks`).

import CAgentProxyPOSIX
import Foundation

/// The relay listener: containers' streams, each named by the relay.
public final class RelayListener: Sendable {
    private let listener: Int32
    private let relayToken: @Sendable () -> String?
    private let proxy: EgressProxy
    private let dns: DNSForwarder?
    private let mcp: (any MCPAnswering)?
    private let dialIns: @Sendable () -> [DialIn]
    private let log: @Sendable (String) -> Void
    private let caps: ConnectionCaps
    private let headTimeout: Int
    private let bodyWithin: TimeInterval
    private let headerTimeout: Double

    /// The most streams at once, in all and of one lease (NCH's review of #414).
    public static let defaultMaxConnections = 512
    public static let defaultMaxConnectionsPerLease = 128
    /// The most streams at once still reading the relay's header, named by
    /// no lease yet (NCH's review of #414).
    public static let defaultMaxUnnamed = 64
    /// How long the request's head may take, in seconds.
    public static let defaultHeadTimeout = 10
    /// The seconds a request's body may take in all, as this listener reads it (an MCP call's, a DNS query's, a plain
    /// request's first 64 KB): on top of each read's `headTimeout` (NCH's review of #451).
    public static let defaultBodyWithin: TimeInterval = 30
    /// How long the relay's header may take, in all, in seconds: the relay
    /// writes it at once (NCH's review of #414).
    public static let defaultHeaderTimeout = 2.0
    /// The largest body a request to the relay listener itself (DNS over
    /// HTTPS, the MCP proxy) may have: 64 KB.
    public static let maxBody = 64 << 10

    /// Listening on loopback at `port`. Nil when the port can't be had.
    /// `relayToken` is the relay's token as the agent proxy holds it now
    /// (nil or empty: no relay set up, so nothing is let in).
    /// `dns`: what answers `POST /dns-query` (none: 404). `mcp`: what
    /// `/mcp/<name>` reaches (none: 404). `dialIns`: the
    /// servers' ports a CONNECT to `<name>.agent.internal` reaches, as they
    /// are now (DialIn). `maxConnections` and `maxConnectionsPerLease`:
    /// the streams carried at once; `maxUnnamed`: those still reading their
    /// header; `headerTimeout`: the seconds the header may take in all;
    /// `headTimeout`: the seconds the request's head may take.
    public init?(port: Int, relayToken: @escaping @Sendable () -> String?, proxy: EgressProxy, dns: DNSForwarder? = nil,
                 mcp: (any MCPAnswering)? = nil, dialIns: @escaping @Sendable () -> [DialIn] = { [] },
                 maxConnections: Int = RelayListener.defaultMaxConnections,
                 maxConnectionsPerLease: Int = RelayListener.defaultMaxConnectionsPerLease,
                 maxUnnamed: Int = RelayListener.defaultMaxUnnamed,
                 headTimeout: Int = RelayListener.defaultHeadTimeout,
                 headerTimeout: Double = RelayListener.defaultHeaderTimeout,
                 bodyWithin: TimeInterval = RelayListener.defaultBodyWithin,
                 log: @escaping @Sendable (String) -> Void) {
        guard (1...65535).contains(port) else { return nil }
        agent_proxy_ignore_broken_pipes()
        listener = agent_proxy_listen(UInt16(port), 0)
        guard listener >= 0 else { return nil }
        self.relayToken = relayToken
        self.proxy = proxy
        self.dns = dns
        self.mcp = mcp
        self.dialIns = dialIns
        self.caps = ConnectionCaps(total: maxConnections, perLease: maxConnectionsPerLease, unnamed: maxUnnamed)
        self.headTimeout = max(headTimeout, 1)
        self.headerTimeout = max(headerTimeout, 0.1)
        self.bodyWithin = max(bodyWithin, 1)
        self.log = log
    }

    public func start() {
        Thread.detachNewThread { [self] in
            while true {
                let stream = agent_proxy_accept(listener)
                if stream < 0 { return }
                guard caps.admit() else {
                    if caps.unnamedFull {
                        if caps.shouldLog("unnamed") { log("relay: \(caps.unnamed) streams still without their header: new ones closed") }
                    } else if caps.shouldLog("all") {
                        log("relay: \(caps.total) streams at once already: new ones closed")
                    }
                    close(stream)
                    continue
                }
                Thread.detachNewThread { [self] in
                    serve(stream)
                    caps.release()
                }
            }
        }
    }

    public func stop() {
        agent_proxy_shutdown(listener)
        close(listener)
    }

    /// Why `maxConnections`, `maxConnectionsPerLease` and `maxUnnamed` would
    /// let one container, or streams naming none, hold every place; nil when
    /// they're sound (shireworks-agent-proxy checks server.json's at its start).
    public static func capsProblem(maxConnections: Int, maxConnectionsPerLease: Int, maxUnnamed: Int = RelayListener.defaultMaxUnnamed) -> String? {
        ConnectionCaps.problem(total: maxConnections, perLease: maxConnectionsPerLease, unnamed: maxUnnamed)
    }

    /// One stream: the relay's header, given `headerTimeout` in all, then the
    /// container's request, given `headTimeout` (what follows them may be as
    /// quiet as it likes: each way that splices clears it).
    private func serve(_ stream: Int32) {
        let header: ProxyProtocolHeader
        do {
            defer { caps.named() }
            header = try ProxyProtocolHeader.read(from: stream, within: headerTimeout)
        } catch {
            log("relay: a stream without the relay's header (\(error)): closed")
            close(stream)
            return
        }
        agent_proxy_set_receive_timeout(stream, Int32(headTimeout))
        guard let lease = header.admittedLease(relayToken: relayToken() ?? "") else {
            if header.command == .proxy {
                log(header.carriesRelayToken(relayToken() ?? "") ? "relay: a stream whose lease id isn't one: closed"
                    : "relay: a stream without the relay's token: closed")
            }
            close(stream)
            return
        }
        guard caps.admit(lease: lease) else {
            if caps.shouldLog(lease) { log("relay: container:\(lease) has \(caps.perLease) streams at once already: new ones refused") }
            HTTPRequest.reply(stream, "503 Service Unavailable", "Too many connections from this container at once.")
            close(stream)
            return
        }
        defer { caps.release(lease: lease) }
        guard let request = HTTPRequest.read(stream, bodyLimit: Self.maxBody, bodyWithin: bodyWithin, perRead: Int32(headTimeout)) else {
            close(stream)
            return
        }
        let caller = EgressProxy.Caller(lease: lease, agent: EgressProxy.agent(in: request))
        let absolute = request.method == "CONNECT" ? nil : EgressProxy.absolute(request.path)
        if request.method == "CONNECT", let destination = EgressProxy.destination(request.path), DialIn.isOwn(destination.host) {
            dialIn(stream, request, to: destination, caller: caller)
        } else if request.method == "CONNECT", let destination = EgressProxy.destination(request.path) {
            proxy.tunnel(stream, request, to: destination, caller: caller)
        } else if let destination = absolute?.destination, DialIn.isOwn(destination.host) {
            // The agent proxy's own names are a dial-in's (by CONNECT): never looked up.
            log("relay: \(caller.session) \(request.method) \(destination.host):\(destination.port) refused: a dial-in is reached by CONNECT")
            record(caller, destination, .dialIn, .refused)
            HTTPRequest.reply(stream, "403 Forbidden", "Refused: \(destination.host) is the agent proxy's own, reached by CONNECT alone.")
            close(stream)
        } else if absolute != nil {
            proxy.forward(stream, request, caller: caller)
        } else if request.path == "/dns-query" {
            answerDNS(stream, request)
        } else if request.path.hasPrefix("/mcp/") {
            answerMCP(stream, request, caller: caller)
        } else if request.method == "GET", request.path == "/" {
            // A container's health probe (`curl … --unix-socket
            // /run/agent-proxy/relay.sock http://agent-proxy/`): the way out
            // answers.
            HTTPRequest.reply(stream, "200 OK", "agent-proxy")
            close(stream)
        } else {
            HTTPRequest.reply(stream, "405 Method Not Allowed", "The agent proxy's relay takes CONNECT, an absolute http:// URL, POST /dns-query or /mcp/<name>.")
            close(stream)
        }
    }

    /// `destination` by one of the agent proxy's own routes, in the egress log.
    private func record(_ caller: EgressProxy.Caller, _ destination: EgressProxy.Destination, _ route: EgressLog.Route,
                        _ outcome: EgressLog.Outcome, agent: String? = nil) {
        proxy.egress?.record(EgressLog.Entry(host: destination.host.lowercased(), port: Int(destination.port), lease: caller.lease,
                                             agentClaimed: agent ?? caller.agent, route: route, outcome: outcome))
    }

    /// A CONNECT to a server on this computer by the agent proxy's name for
    /// it: joined to its loopback port, if it's a dial-in; refused otherwise.
    private func dialIn(_ stream: Int32, _ request: HTTPRequest, to destination: EgressProxy.Destination, caller: EgressProxy.Caller) {
        let target = "\(destination.host):\(destination.port)"
        guard let dialIn = DialIn.matching(destination.host, Int(destination.port), in: dialIns()) else {
            log("relay: \(caller.session) CONNECT \(target) refused: not a dial-in")
            record(caller, destination, .dialIn, .refused)
            HTTPRequest.reply(stream, "403 Forbidden", "Refused: \(target) is not one of the agent proxy's dial-ins.")
            close(stream)
            return
        }
        let server = agent_proxy_connect_tcp("127.0.0.1", UInt16(dialIn.hostPort))
        guard server >= 0 else {
            log("relay: \(caller.session) CONNECT \(target) unreachable: nothing answers at loopback port \(dialIn.hostPort)")
            record(caller, destination, .dialIn, .unreachable)
            HTTPRequest.reply(stream, "502 Bad Gateway", "\(target) can't be reached.")
            close(stream)
            return
        }
        log("relay: \(caller.session) CONNECT \(target) dial-in to loopback port \(dialIn.hostPort)")
        record(caller, destination, .dialIn, .tunnelled)
        HTTPRequest.send(stream, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
        // What the client sent after its CONNECT, already.
        if !request.body.isEmpty { HTTPRequest.send(server, request.body) }
        // A dial-in may be quiet for as long as it likes (gRPC's streams are).
        agent_proxy_set_receive_timeout(stream, 0)
        Splice.join(stream, server)
    }

    /// An MCP server's call from the container (`mcp`'s to answer); 404
    /// without one.
    private func answerMCP(_ stream: Int32, _ request: HTTPRequest, caller: EgressProxy.Caller) {
        defer { close(stream) }
        guard let mcp else {
            HTTPRequest.reply(stream, "404 Not Found", "No MCP servers here.")
            return
        }
        guard request.unreadBody == 0 else {
            HTTPRequest.reply(stream, "413 Content Too Large", "A call of at most \(Self.maxBody) bytes.")
            return
        }
        log("relay: \(caller.session) \(request.method) \(request.path.prefix { $0 != "?" })")
        mcp.answerMCP(stream, request, caller: caller)
    }

    /// DNS over HTTPS's wire form (RFC 8484): a query posted as
    /// application/dns-message, answered by the resolver the same way.
    private func answerDNS(_ stream: Int32, _ request: HTTPRequest) {
        defer { close(stream) }
        guard let dns else {
            HTTPRequest.reply(stream, "404 Not Found", "No resolver here.")
            return
        }
        guard request.unreadBody == 0, request.body.count <= Self.maxBody else {
            HTTPRequest.reply(stream, "413 Content Too Large", "A DNS query of at most \(Self.maxBody) bytes.")
            return
        }
        guard request.method == "POST", request.header("Content-Type")?.lowercased() == "application/dns-message",
              let query = DNSMessage(Array(request.body)) else {
            HTTPRequest.reply(stream, "400 Bad Request", "POST a DNS query as application/dns-message.")
            return
        }
        let answered = AnsweredDNS()
        Task {
            let answer = await dns.answer(query)
            answered.value.withLock { $0 = answer }
            answered.done.signal()
        }
        answered.done.wait()
        guard let answer = answered.value.withLock({ $0 }) else {
            HTTPRequest.reply(stream, "400 Bad Request", "Not a DNS query.")
            return
        }
        HTTPRequest.send(stream, Data(("HTTP/1.1 200 OK\r\nContent-Type: application/dns-message\r\n"
            + "Content-Length: \(answer.bytes.count)\r\nConnection: close\r\n\r\n").utf8) + Data(answer.bytes))
    }
}

/// An answer handed from the resolver's task to the thread waiting for it.
private final class AnsweredDNS: Sendable {
    let value = Locked<DNSMessage?>(nil)
    let done = DispatchSemaphore(value: 0)
}
