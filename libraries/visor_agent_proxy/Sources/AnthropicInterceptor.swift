// agent-proxy's side for Anthropic's API (docs/containers.md, "Claude's
// credential"): a container's CONNECT to api.anthropic.com on port 443 is
// opened here with a leaf of agent-proxy's Anthropic authority
// (AgentProxyCA.Scope.anthropic, constrained to that one name), and each
// request in it goes on with the Claude credential agent-proxy keeps
// (`agent-proxy/claude/oauth-token`, a `claude setup-token` token): whatever
// the agent sent as `Authorization` or `x-api-key` (its placeholder,
// `CLAUDE_CODE_OAUTH_TOKEN=visor-agent-proxy`) is taken off, `Authorization:
// Bearer <token>` put on, and `oauth-2025-04-20` merged into
// `anthropic-beta`. The token never reaches the container: it's added on
// the way out, and masked should an answer echo it. With none kept, each
// request is answered 401 in Anthropic's own error form, saying where to
// sign in. Each request is a line of the egress log (route `anthropic`): its
// method, its path's class and whether it went on; never a body, a header or
// the token.

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

/// Anthropic's API, opened: each request sent on with the Claude credential.
public final class AnthropicInterceptor: GitHubIntercepting, Sendable {
    /// The one host it opens.
    public static let host = "api.anthropic.com"
    /// The beta a Claude subscription's OAuth token is taken under.
    public static let oauthBeta = "oauth-2025-04-20"
    /// What a request is told with no credential kept.
    public static let noCredential = "Visor's agent-proxy has no Claude credential: Sign In to Claude in Visor's Settings › Sessions Container."

    /// How Anthropic is reached: its host, with the system's trust; in a
    /// test, a stand-in's address and authority.
    struct Upstream: Sendable {
        var address: @Sendable (String) -> (host: String, port: Int)
        var tls: TLSConfiguration

        static let anthropic = Upstream(address: { ($0, 443) }, tls: .makeClientConfiguration())
    }

    /// The credential as kept now; nil or empty for none.
    let token: @Sendable () -> String?
    let upstream: Upstream
    let log: @Sendable (String) -> Void
    /// Where each request is logged (none: the lines of `log` alone).
    let egress: EgressLog?
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let upstreamContext: NIOSSLContext
    private let ca: AgentProxyCA
    /// The host's TLS context, with its leaf, and when it was made: a leaf is
    /// good for a week and made again after a day.
    private let leafContext = Locked<(context: NIOSSLContext, made: Date)?>(nil)

    init(ca: AgentProxyCA, token: @escaping @Sendable () -> String?, upstream: Upstream = .anthropic, egress: EgressLog? = nil,
         log: @escaping @Sendable (String) -> Void) throws {
        self.ca = ca
        self.token = token
        self.upstream = upstream
        self.egress = egress
        self.log = log
        upstreamContext = try NIOSSLContext(configuration: upstream.tls)
    }

    /// The interceptor, or nil (the reason logged): its authority, kept in
    /// `secrets` and made the first time, its certificate written to
    /// `caCertificate` (mode 644) for the containers to trust; `token`, the
    /// credential as kept now. Without the authority there is none, and
    /// api.anthropic.com is a plain tunnel.
    public static func make(secrets: any AgentProxySecrets, caCertificate: String, token: @escaping @Sendable () -> String?,
                            egress: EgressLog?, log: @escaping @Sendable (String) -> Void) -> AnthropicInterceptor? {
        let ca: AgentProxyCA
        do {
            ca = try AgentProxyCA.kept(in: secrets, scope: .anthropic)
        } catch {
            log("anthropic: its authority couldn't be read or made (\(error)): api.anthropic.com is plain egress")
            return nil
        }
        do {
            try ca.writeCertificate(to: caCertificate)
        } catch {
            log("anthropic: its authority's certificate couldn't be written to \(caCertificate): \(error)")
        }
        do {
            let interceptor = try AnthropicInterceptor(ca: ca, token: token, egress: egress, log: log)
            log("anthropic: api.anthropic.com is opened with the authority in \(caCertificate)"
                + (token()?.isEmpty == false ? ", with the Claude credential" : "; no Claude credential yet: each request is refused"))
            return interceptor
        } catch {
            log("anthropic: no TLS for api.anthropic.com (\(error)): it is plain egress")
            return nil
        }
    }

    public func stop() {
        group.shutdownGracefully { _ in }
    }

    /// api.anthropic.com, on port 443.
    public func intercepts(_ destination: EgressProxy.Destination) -> Bool {
        destination.port == 443 && destination.host.lowercased() == Self.host
    }

    /// A tunnel's client, its CONNECT answered: TLS as the host, then its
    /// requests, each sent on with the credential. Returns once the client's
    /// stream has closed.
    public func adopt(_ client: Int32, host: String, caller: EgressProxy.Caller) {
        let context: NIOSSLContext
        do {
            context = try serverContext()
        } catch {
            log("\(caller.session) \(host): no leaf could be made: \(error)")
            close(client)
            return
        }
        let interceptor = self
        let channel: Channel
        do {
            channel = try ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let operations = channel.pipeline.syncOperations
                        try operations.addHandler(NIOSSLServerHandler(context: context))
                        try operations.configureHTTPServerPipeline(withErrorHandling: true)
                        try operations.addHandler(RequestHandler(interceptor: interceptor, caller: caller))
                    }
                }
                .withConnectedSocket(client)
                .wait()
        } catch {
            log("\(caller.session) \(host): the tunnel wasn't taken: \(error)")
            return
        }
        try? channel.closeFuture.wait()
    }

    private func serverContext() throws -> NIOSSLContext {
        if let held = leafContext.withLock({ $0 }), Date().timeIntervalSince(held.made) < 24 * 3600 { return held.context }
        let (leaf, key) = try ca.leaf(for: Self.host)
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: Array(try leaf.serializeAsPEM().pemString.utf8), format: .pem)),
                               .certificate(try NIOSSLCertificate(bytes: Array(try ca.pem.utf8), format: .pem))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(key.pemRepresentation.utf8), format: .pem)))
        configuration.applicationProtocols = ["http/1.1"]
        let made = try NIOSSLContext(configuration: configuration)
        leafContext.withLock { $0 = (made, Date()) }
        return made
    }

    /// The credential kept now, trimmed; nil for none.
    var credential: String? {
        guard let token = token()?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        return token
    }

    /// A request's headers as they go on: the agent's own credentials and
    /// the proxy's headers taken off, `token` as the bearer, and the OAuth
    /// beta merged into `anthropic-beta` (each beta once, in the order
    /// given, the OAuth one last if it wasn't there).
    static func outgoing(_ given: HTTPHeaders, token: String) -> HTTPHeaders {
        var headers = given
        for name in ["authorization", "x-api-key", "proxy-authorization", "proxy-connection"] { headers.remove(name: name) }
        headers.replaceOrAdd(name: "host", value: host)
        // Its answer as plain bytes, so a token in it can be found and masked.
        headers.replaceOrAdd(name: "accept-encoding", value: "identity")
        headers.add(name: "authorization", value: "Bearer " + token)
        var betas: [String] = []
        for value in headers["anthropic-beta"] {
            for beta in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !beta.isEmpty && !betas.contains(beta) {
                betas.append(beta)
            }
        }
        if !betas.contains(oauthBeta) { betas.append(oauthBeta) }
        headers.replaceOrAdd(name: "anthropic-beta", value: betas.joined(separator: ","))
        return headers
    }

    /// The answer to a request with no credential kept: 401, in Anthropic's
    /// error form (`{"type":"error","error":{"type":"authentication_error",…}}`),
    /// which Claude Code shows as it shows Anthropic's own.
    static func refusal() -> (HTTPResponseHead, [UInt8]) {
        let object: [String: Any] = ["type": "error", "error": ["type": "authentication_error", "message": noCredential]]
        let bytes = Array((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data())
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "application/json")
        headers.add(name: "content-length", value: "\(bytes.count)")
        return (HTTPResponseHead(version: .http1_1, status: .unauthorized, headers: headers), bytes)
    }

    /// One request, as it went, in the egress log: no body, header or token.
    func record(_ caller: EgressProxy.Caller, method: String, uri: String, _ outcome: EgressLog.Outcome) {
        egress?.record(EgressLog.Entry(host: Self.host, port: 443, lease: caller.lease, agentClaimed: caller.agent, route: .anthropic,
                                       outcome: outcome, method: method, pathClass: GitHubGate.pathClass(uri),
                                       decision: outcome == .refused ? "refuse" : "allow"))
    }
}
