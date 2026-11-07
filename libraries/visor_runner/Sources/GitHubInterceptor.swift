import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Synchronization

/// The GitHub proxy's side for GitHub's own hosts (docs/github-proxy.md): a
/// tunnel to github.com, api.github.com or uploads.github.com is opened here
/// with a leaf of the Runner's authority, and each request in it is read as
/// far as GitHubGate needs, decided, checked against GitHub where the gate
/// says, and either sent on with the session's token or answered with a
/// refusal in its client's own form. The token never reaches the agent.
final class GitHubInterceptor: Sendable {
    /// How GitHub is reached: its hosts, with the system's trust; in a test,
    /// a stand-in's address and authority.
    struct Upstream: Sendable {
        var address: @Sendable (String) -> (host: String, port: Int)
        var tls: TLSConfiguration

        static let github = Upstream(address: { ($0, 443) }, tls: .makeClientConfiguration())
    }

    let gate: GitHubGate
    let tokens: any GitHubTokenSource
    let reader: @Sendable (String) -> any GitHubReading
    let upstream: Upstream
    let log: @Sendable (String) -> Void
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let upstreamContext: NIOSSLContext
    private let ca: RunnerCA
    /// Each host's TLS context, with its leaf, and when it was made: a leaf is
    /// good for a week and made again after a day.
    private let contexts = Mutex<[String: (context: NIOSSLContext, made: Date)]>([:])

    init(gate: GitHubGate, ca: RunnerCA, tokens: any GitHubTokenSource,
         reader: @escaping @Sendable (String) -> any GitHubReading = { GitHubAPIReader(token: $0) },
         upstream: Upstream = .github, log: @escaping @Sendable (String) -> Void) throws {
        self.gate = gate
        self.ca = ca
        self.tokens = tokens
        self.reader = reader
        self.upstream = upstream
        self.log = log
        upstreamContext = try NIOSSLContext(configuration: upstream.tls)
    }

    func stop() {
        group.shutdownGracefully { _ in }
    }

    /// A tunnel's client, its CONNECT answered: TLS as `host`, then its
    /// requests, each as GitHubGate decides.
    func adopt(_ socket: Int32, host: String, caller: GitHubProxy.Caller) {
        let context: NIOSSLContext
        do {
            context = try serverContext(for: host)
        } catch {
            log("\(caller.session) \(host): no leaf could be made: \(error)")
            close(socket)
            return
        }
        let interceptor = self
        ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let operations = channel.pipeline.syncOperations
                    try operations.addHandler(NIOSSLServerHandler(context: context))
                    try operations.configureHTTPServerPipeline(withErrorHandling: true)
                    try operations.addHandler(RequestHandler(interceptor: interceptor, host: host, caller: caller))
                }
            }
            .withConnectedSocket(socket)
            .whenFailure { [log] error in log("\(caller.session) \(host): the tunnel wasn't taken: \(error)") }
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

    /// What became of a decision once its checks have run.
    enum Settled: Sendable {
        case forward(repository: String, token: String, rewrite: CheckOutcome.Rewrite?)
        case refuse(String)
        case fail(String)
    }

    /// A decision, its check made and its token got.
    func settle(_ decision: GateDecision, caller: GitHubProxy.Caller) async -> Settled {
        let repository: String?
        var rewrite: CheckOutcome.Rewrite?
        switch decision {
        case .refuse(let reason):
            return .refuse(reason)
        case .allow(let named):
            repository = named ?? caller.repository
        case .check(let check):
            guard let named = Self.repository(of: check) ?? caller.repository else {
                return .fail("Visor's proxy doesn't know this session's repository, to ask for its token")
            }
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
        guard let repository else { return .fail("Visor's proxy doesn't know this session's repository, to ask for its token") }
        do {
            return .forward(repository: repository, token: try await tokens.token(session: caller.session, repository: repository), rewrite: rewrite)
        } catch {
            return .fail("\(error)")
        }
    }

    /// The repository a check is of, where it names one (a GraphQL one's is
    /// found by the check itself, with the session's own repository's token).
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
