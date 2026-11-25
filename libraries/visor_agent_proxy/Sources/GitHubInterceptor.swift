// agent-proxy's side for GitHub's own hosts (MultiPass's GitHubInterceptor,
// moved; Logan, 2026-11-14): it fills the egress proxy's GitHubIntercepting
// seam. A container's CONNECT to github.com, api.github.com or
// uploads.github.com on port 443 is opened here with a leaf of agent-proxy's
// own authority (AgentProxyCA), and each request in it is read as far as
// GitHubGate needs, decided, checked against GitHub where the gate says, and
// either sent on with the configured GitHub credential (PreferredGitHubToken:
// the GitHub App's installation token, or the auth token) or answered with
// a refusal in its client's own form. The token never reaches the container:
// it is added on the way out, and masked should GitHub's answer echo it.
// Each request is a line of the egress log (route `github`): its method, its
// path's class, the gate's decision and how it went; never a body, a header
// or a token. The container agents' git identity is asked of it too
// (gitIdentity): the GitHub App's bot, while the App's are the tokens.

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

/// GitHub's hosts, opened: requests decided by the gate, and sent on with
/// the configured auth token.
public final class GitHubInterceptor: GitHubIntercepting, Sendable {
    /// How GitHub is reached: its hosts, with the system's trust; in a test,
    /// a stand-in's address and authority.
    struct Upstream: Sendable {
        var address: @Sendable (String) -> (host: String, port: Int)
        var tls: TLSConfiguration
        /// How long a connection is held back once made: a test's, as a far
        /// GitHub's would be.
        var delay: TimeAmount = .zero

        static let github = Upstream(address: { ($0, 443) }, tls: .makeClientConfiguration())
    }

    let gate: GitHubGate
    let tokens: any GitHubTokenSource
    let reader: @Sendable (String) -> any GitHubReading
    let upstream: Upstream
    let log: @Sendable (String) -> Void
    /// Where each request is logged (none: the lines of `log` alone).
    let egress: EgressLog?
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let upstreamContext: NIOSSLContext
    private let ca: AgentProxyCA
    /// Each host's TLS context, with its leaf, and when it was made: a leaf is
    /// good for a week and made again after a day.
    private let contexts = Locked<[String: (context: NIOSSLContext, made: Date)]>([:])

    init(gate: GitHubGate, ca: AgentProxyCA, tokens: any GitHubTokenSource,
         reader: @escaping @Sendable (String) -> any GitHubReading = { GitHubAPIReader(token: $0) },
         upstream: Upstream = .github, egress: EgressLog? = nil, log: @escaping @Sendable (String) -> Void) throws {
        self.gate = gate
        self.ca = ca
        self.tokens = tokens
        self.reader = reader
        self.upstream = upstream
        self.egress = egress
        self.log = log
        upstreamContext = try NIOSSLContext(configuration: upstream.tls)
    }

    public func stop() {
        group.shutdownGracefully { _ in }
    }

    /// The git identity the container's agents commit as: the GitHub App's
    /// bot, found once for its secrets (GitHubAppTokens); nil without the
    /// App, or when it couldn't be found (said in the log, once).
    public func gitIdentity() async -> GitHubAppIdentity? {
        await tokens.identity()
    }

    /// GitHub's three hosts, on port 443.
    public func intercepts(_ destination: EgressProxy.Destination) -> Bool {
        destination.port == 443 && GitHubHosts.contains(destination.host)
    }

    /// A tunnel's client, its CONNECT answered: TLS as `host`, then its
    /// requests, each as GitHubGate decides. Returns once the client's stream
    /// has closed, so the relay listener's caps count it as they count a
    /// tunnel.
    public func adopt(_ client: Int32, host: String, caller: EgressProxy.Caller) {
        let context: NIOSSLContext
        do {
            context = try serverContext(for: host)
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
                        try operations.addHandler(RequestHandler(interceptor: interceptor, host: host, caller: caller))
                    }
                }
                .withConnectedSocket(client)
                .wait()
        } catch {
            // The bootstrap holds the descriptor from its start, and closes it.
            log("\(caller.session) \(host): the tunnel wasn't taken: \(error)")
            return
        }
        try? channel.closeFuture.wait()
    }

    private func serverContext(for host: String) throws -> NIOSSLContext {
        if let held = contexts.withLock({ $0[host] }), Date().timeIntervalSince(held.made) < 24 * 3600 { return held.context }
        let (leaf, key) = try ca.leaf(for: host)
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: Array(try leaf.serializeAsPEM().pemString.utf8), format: .pem)),
                               .certificate(try NIOSSLCertificate(bytes: Array(try ca.pem.utf8), format: .pem))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(key.pemRepresentation.utf8), format: .pem)))
        configuration.applicationProtocols = ["http/1.1"]
        let context = try NIOSSLContext(configuration: configuration)
        contexts.withLock { $0[host] = (context, Date()) }
        return context
    }

    /// One request, as it went, in the egress log: no body, header or token.
    func record(_ caller: EgressProxy.Caller, host: String, method: String, uri: String, decision: GateDecision?,
                _ outcome: EgressLog.Outcome) {
        egress?.record(EgressLog.Entry(host: host, port: 443, lease: caller.lease, agentClaimed: caller.agent, route: .github,
                                       outcome: outcome, method: method, pathClass: GitHubGate.pathClass(uri),
                                       decision: decision.map(\.kind) ?? "refuse"))
    }

    /// What became of a decision once its checks have run.
    enum Settled: Sendable {
        case forward(repository: String, token: String, rewrite: CheckOutcome.Rewrite?)
        /// On with no token at all: a read outside the allowed repositories,
        /// or one of theirs with no token configured.
        case anonymous(repository: String)
        case refuse(String)
        case fail(String)
    }

    /// A decision, its check made and its token got. `request`: what it was
    /// made of, read again only when no token is configured.
    func settle(_ decision: GateDecision, request: GateRequest, caller: EgressProxy.Caller) async -> Settled {
        let repository: String?
        var rewrite: CheckOutcome.Rewrite?
        switch decision {
        case .refuse(let reason):
            return .refuse(reason)
        case .anonymous(let named):
            // No token at all: none is asked for, and none goes on.
            return .anonymous(repository: named)
        case .allow(let named):
            repository = named
        case .check(let check):
            let named = Self.repository(of: check) ?? ""
            let token: String
            do {
                token = try await tokens.token(session: caller.session, repository: named)
            } catch {
                return .fail("\(error)")
            }
            switch await GateChecker(rules: gate.rules, github: reader(token)).run(check) {
            case .refuse(let reason): return .refuse(reason)
            case .fail(let reason): return .fail(reason)
            case .pass(let given): rewrite = given
            }
            repository = named
        }
        // One token for every agent: the repository is the log's.
        let named = repository ?? ""
        do {
            return .forward(repository: named, token: try await tokens.token(session: caller.session, repository: named), rewrite: rewrite)
        } catch is NoGitHubToken where gate.isRead(request) {
            // None configured: a read of an allowed repository goes on as
            // one outside them does (Logan, 9 Nov 2026). A token GitHub
            // turned down, or one that couldn't be made, is no reason to.
            return .anonymous(repository: named)
        } catch {
            return .fail("\(error)")
        }
    }

    /// The repository a check is of, where it names one (a GraphQL one's is
    /// found by the check itself).
    static func repository(of check: GateCheck) -> String? {
        switch check {
        case .merge(let repository, _, _, _), .updateBranch(let repository, _), .rerun(let repository, _, _), .cancel(let repository, _),
             .dispatch(let repository, _, _), .releaseEdit(let repository, _), .push(let repository, _):
            return repository
        case .graphQLMerge, .graphQLUpdateBranch, .graphQLNodes:
            return nil
        }
    }
}

extension GateDecision {
    /// As the egress log names it: allow, anonymous, check or refuse.
    var kind: String {
        switch self {
        case .allow: "allow"
        case .anonymous: "anonymous"
        case .check: "check"
        case .refuse: "refuse"
        }
    }
}

extension GitHubGate {
    /// A request's path as the egress log keeps it: no query, each number
    /// `{n}` and each commit's id `{sha}`, at most eight segments.
    public static func pathClass(_ uri: String) -> String {
        let path = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map { segment -> String in
            if !segment.isEmpty, segment.allSatisfy({ $0.isASCII && $0.isNumber }) { return "{n}" }
            if GitRefName.isSHA(String(segment)) { return "{sha}" }
            return String(segment.prefix(100))
        }
        return "/" + (segments.count > 8 ? segments.prefix(8).joined(separator: "/") + "/…" : segments.joined(separator: "/"))
    }
}
