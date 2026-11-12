// The GitHub proxy end to end (docs/github-proxy.md, rollout step 3c): curl,
// as an agent's git and gh would, through the proxy to a stand-in for GitHub
// over TLS. GitHub's host opened with the Runner's authority; what GitHubGate
// allows goes on with the session's token in place of the agent's
// placeholder, and the token never comes back; what it refuses is answered
// in the client's own form and never reaches GitHub.

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Synchronization
@testable import VisorRunner
import Testing

/// The token every session gets here.
private struct FixedTokens: GitHubTokenSource {
    func token(session: String, repository: String) async throws -> String { "ghs_fixedtoken" }
    func forget(session: String, repository: String) async {}
}

/// What the stand-in GitHub was sent, one line a request.
private final class Heard: Sendable {
    let lines = Mutex<[String]>([])
}

/// GitHub played over TLS: it answers each request with what it was sent,
/// and keeps what it was sent.
private final class EchoGitHub: Sendable {
    let port: Int
    let heard = Heard()
    private let channel: Channel

    init(ca: RunnerCA, group: EventLoopGroup) throws {
        let (leaf, key) = try ca.leaf(for: "api.github.com")
        let context = try NIOSSLContext(configuration: .makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: Array(try leaf.serializeAsPEM().pemString.utf8), format: .pem))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(key.pemRepresentation.utf8), format: .pem))))
        let heard = self.heard
        channel = try ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(Echo(heard: heard))
                }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
        port = channel.localAddress?.port ?? 0
    }

    var requests: [String] { heard.lines.withLock { $0 } }

    func stop() { try? channel.close().wait() }

    final class Echo: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart
        let heard: Heard
        var head: HTTPRequestHead?

        init(heard: Heard) { self.heard = heard }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let given): head = given
            case .body: break
            case .end:
                guard let head else { return }
                let line = "\(head.method.rawValue) \(head.uri) \(head.headers["authorization"].first ?? "")"
                heard.lines.withLock { $0.append(line) }
                let body = Array("{\"heard\":\"\(line)\"}".utf8)
                var headers = HTTPHeaders()
                headers.add(name: "content-type", value: "application/json")
                headers.add(name: "content-length", value: "\(body.count)")
                context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
                var buffer = context.channel.allocator.buffer(capacity: body.count)
                buffer.writeBytes(body)
                context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}

@Suite final class GitHubInterceptorTests {
    private var group: MultiThreadedEventLoopGroup!
    private var github: EchoGitHub!
    private var proxy: GitHubProxy!
    private var port = 0
    private var caFile: URL!

    init() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let githubCA = try RunnerCA.make(now: Date())
        github = try EchoGitHub(ca: githubCA, group: group)
        let proxyCA = try RunnerCA.make(now: Date())
        caFile = FileManager.default.temporaryDirectory.appendingPathComponent("visor-proxy-ca-\(UUID().uuidString).pem")
        try proxyCA.pem.write(to: caFile, atomically: true, encoding: .utf8)
        var trust = TLSConfiguration.makeClientConfiguration()
        trust.trustRoots = .certificates([try NIOSSLCertificate(bytes: Array(try githubCA.pem.utf8), format: .pem)])
        let githubPort = github.port
        let interceptor = try GitHubInterceptor(gate: GitHubGate(), ca: proxyCA, tokens: FixedTokens(),
                                                upstream: .init(address: { _ in ("127.0.0.1", githubPort) }, tls: trust), log: { _ in })
        for _ in 0..<20 {
            let candidate = Int.random(in: 20000...45000)
            if let made = GitHubProxy(port: candidate, admits: { $0 == "server-token" }, interceptor: interceptor, log: { _ in }) {
                made.start()
                proxy = made
                port = candidate
                break
            }
        }
        guard proxy != nil else { try Test.cancel("no port for the proxy") }
    }

    deinit {
        proxy?.stop()
        github?.stop()
        try? FileManager.default.removeItem(at: caFile)
        try? group?.syncShutdownGracefully()
    }

    /// curl through the proxy as the session's agent, trusting the Runner's
    /// authority, with gh's placeholder token.
    private func agent(_ arguments: [String]) throws -> (body: String, status: String) {
        try curl(["--proxy", "http://127.0.0.1:\(port)", "--proxy-user", "server-token:session-a@AttilaTheFun/shireworks",
                  "--cacert", caFile.path, "-H", "Authorization: token placeholder"] + arguments)
    }

    @Test func testAReadGoesOnWithTheSessionsTokenWhichNeverComesBack() throws {
        let (body, status) = try agent(["https://api.github.com/repos/AttilaTheFun/shireworks/pulls/3"])
        #expect(status == "200", Comment(rawValue: body))
        #expect(github.requests == ["GET /repos/AttilaTheFun/shireworks/pulls/3 Bearer ghs_fixedtoken"], "the placeholder replaced")
        #expect(body.contains("Bearer " + String(repeating: "*", count: "ghs_fixedtoken".count)), "masked on its way back: \(body)")
        #expect(!body.contains("ghs_fixedtoken"))
    }

    @Test func testARefusalIsGitHubsOwnFormAndNeverReachesGitHub() throws {
        let rest = try agent(["-X", "DELETE", "https://api.github.com/repos/AttilaTheFun/shireworks/git/refs/heads/x"])
        #expect(rest.status == "403", Comment(rawValue: rest.body))
        #expect(rest.body.contains("\"message\":\"Refused:"), Comment(rawValue: rest.body))
        let graphQL = try agent(["-X", "POST", "-H", "Content-Type: application/json", "--data",
                                 #"{"query":"mutation { deleteRef(input: {refId: \"R\"}) { clientMutationId } }"}"#,
                                 "https://api.github.com/graphql"])
        #expect(graphQL.status == "200", Comment(rawValue: graphQL.body))
        #expect(graphQL.body.contains("\"type\":\"FORBIDDEN\""), Comment(rawValue: graphQL.body))
        let other = try agent(["-X", "POST", "-H", "Content-Type: application/json", "--data", #"{"body":"x"}"#,
                               "https://api.github.com/repos/someone/else/issues/3/comments"])
        #expect(other.status == "403", Comment(rawValue: other.body))
        #expect(other.body.contains("not among the repositories"), Comment(rawValue: other.body))
        #expect(github.requests == [], "nothing refused reached GitHub")
    }

    /// Logan, 9 Nov 2026: a read of a repository outside the allowed ones
    /// goes on with no authorization at all: neither the session's token nor
    /// the client's placeholder reaches GitHub.
    @Test func testAReadOutsideTheAllowedRepositoriesGoesOnWithNoToken() throws {
        let (body, status) = try agent(["https://api.github.com/repos/swiftlang/swift-foundation/tags"])
        #expect(status == "200", Comment(rawValue: body))
        #expect(github.requests == ["GET /repos/swiftlang/swift-foundation/tags "], "no authorization header")
        #expect(!body.contains("ghs_fixedtoken"))
        #expect(!body.contains("placeholder"))
        // An allowed one's read after it still has the token.
        _ = try agent(["https://api.github.com/repos/AttilaTheFun/shireworks/pulls/3"])
        #expect(github.requests.last == "GET /repos/AttilaTheFun/shireworks/pulls/3 Bearer ghs_fixedtoken")
    }

    @Test func testAnAllowedWriteGoesOnWithItsBody() throws {
        let (body, status) = try agent(["-X", "POST", "-H", "Content-Type: application/json", "--data", #"{"body":"Looks right"}"#,
                                        "https://api.github.com/repos/AttilaTheFun/shireworks/issues/3/comments"])
        #expect(status == "200", Comment(rawValue: body))
        #expect(github.requests == ["POST /repos/AttilaTheFun/shireworks/issues/3/comments Bearer ghs_fixedtoken"])
    }

    /// A push to main, refused as git reads a push's answer: report-status,
    /// the ref turned down, in side-band as asked.
    @Test func testAPushToMainIsTurnedDownAsGitShowsIt() throws {
        let zero = String(repeating: "0", count: 40), sha = String(repeating: "a", count: 40)
        let line = "\(zero) \(sha) refs/heads/main\0report-status side-band-64k\n"
        let body = String(format: "%04x", line.utf8.count + 4) + line + "0000PACK"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("visor-push-\(UUID().uuidString)")
        try Data(body.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let (answer, status) = try agent(["-X", "POST", "-H", "Content-Type: application/x-git-receive-pack-request",
                                          "--data-binary", "@\(file.path)", "https://github.com/AttilaTheFun/shireworks.git/git-receive-pack"])
        #expect(status == "200", Comment(rawValue: answer))
        #expect(answer.contains("ng refs/heads/main Refused: main is never pushed"), Comment(rawValue: answer))
        #expect(github.requests == [])
    }

    @Test func testOnlyAServersAgentsAreLetIn() throws {
        let (_, status) = try curl(["--proxy", "http://127.0.0.1:\(port)", "--proxy-user", "stranger:session-a", "--cacert", caFile.path,
                                    "https://api.github.com/repos/AttilaTheFun/shireworks/pulls"])
        #expect(status != "200")
        #expect(github.requests == [])
    }
}
