// GitHub through agent-proxy end to end (MultiPass's GitHubInterceptorTests,
// moved; Logan, 2026-11-14): a container's stream through the relay
// listener, its CONNECT to GitHub's host opened with agent-proxy's authority,
// and its requests over TLS, as git, gh and curl send them, to a stand-in for
// GitHub. What GitHubGate allows goes on with logan-shire-agent's token in
// place of the client's placeholder, and the token never comes back; what
// it refuses (merging, publishing a release and deleting a ref among them,
// Logan's alone) is answered in the client's own form and never reaches
// GitHub. Each request is a line of the egress log, with nothing of its
// headers, body or token.

import CAgentProxyPOSIX
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
@testable import VisorAgentProxy
import XCTest

/// The token every request gets here.
private struct FixedTokens: GitHubTokenSource {
    func token(session: String, repository: String) async throws -> String { "ghs_fixedtoken" }
    func forget(session: String, repository: String) async {}
}

/// A source whose token can't be had for another reason than none being
/// configured (an App's that couldn't be minted, say): nothing goes on.
private struct BrokenTokens: GitHubTokenSource {
    struct Broken: Error, CustomStringConvertible {
        var description: String { "the token couldn't be made" }
    }

    func token(session: String, repository: String) async throws -> String { throw Broken() }
    func forget(session: String, repository: String) async {}
}

/// The GitHub App's installation token, and its bot (Logan, 25 Nov 2026:
/// an agent closes what its bot opened).
private struct AppTokens: GitHubTokenSource {
    func token(session: String, repository: String) async throws -> String { "ghs_fixedtoken" }
    func forget(session: String, repository: String) async {}
    func identity() async -> GitHubAppIdentity? { GitHubAppIdentity(slug: "logan-shire-agent", userID: 987) }
}

/// GitHub's API as a close's check reads it, each read kept with the token
/// it was made with: #3 and PR_bot the bot's pull request, #4 and I_bot its
/// issue; #5 and PR_logan Logan's pull request, #6 and I_logan his issue.
private struct Authors: GitHubReading {
    let token: String
    let reads: Locked<[String]>

    func get(_ path: String) async -> GitHubAnswer {
        reads.withLock { $0.append("GET \(path) \(token)") }
        let authors: [String: (pull: Bool, login: String)] = [
            "3": (true, "logan-shire-agent[bot]"), "4": (false, "logan-shire-agent[bot]"), "5": (true, "AttilaTheFun"), "6": (false, "AttilaTheFun"),
        ]
        let number = String(path.split(separator: "/").last ?? "")
        guard path.hasPrefix("/repos/AttilaTheFun/shireworks/issues/"), let author = authors[number] else { return GitHubAnswer(status: 404, json: nil) }
        var issue: [String: GateJSON] = ["number": .number(number), "user": .object(["login": .string(author.login)])]
        if author.pull { issue["pull_request"] = .object(["url": .string("x")]) }
        return GitHubAnswer(status: 200, json: .object(issue))
    }

    func graphQL(_ query: String, variables: [String: GateJSON]) async -> GitHubAnswer {
        let id = variables["id"]?.string ?? ""
        reads.withLock { $0.append("graphql \(id) \(token)") }
        let nodes: [String: (kind: String, type: String, login: String)] = [
            "PR_bot": ("PullRequest", "Bot", "logan-shire-agent"), "I_bot": ("Issue", "Bot", "logan-shire-agent"),
            "PR_logan": ("PullRequest", "User", "AttilaTheFun"), "I_logan": ("Issue", "User", "AttilaTheFun"),
        ]
        guard let node = nodes[id] else { return GitHubAnswer(status: 200, json: .object(["data": .object(["node": .null])])) }
        return GitHubAnswer(status: 200, json: .object(["data": .object(["node": .object([
            "__typename": .string(node.kind), "number": .number("3"),
            "author": .object(["__typename": .string(node.type), "login": .string(node.login)]),
            "repository": .object(["nameWithOwner": .string("AttilaTheFun/shireworks")]),
        ])])]))
    }
}

/// GitHub's API as the checks read it: every repository's default branch is main.
private struct DefaultBranchMain: GitHubReading {
    func get(_ path: String) async -> GitHubAnswer { GitHubAnswer(status: 200, json: .object(["default_branch": .string("main")])) }
    func graphQL(_ query: String, variables: [String: GateJSON]) async -> GitHubAnswer { GitHubAnswer(status: 404, json: nil) }
}

/// GitHub played over TLS: it answers each request with what it was sent,
/// and keeps what it was sent.
private final class EchoGitHub: Sendable {
    let port: Int
    let heard = Locked<[String]>([])
    /// Each request's body's length, and the headers it came with (names,
    /// lower case, and accept-encoding's value).
    let bodies = Locked<[Int]>([])
    let headers = Locked<[[String]]>([])
    private let channel: Channel

    init(ca: AgentProxyCA, group: EventLoopGroup, host: String = "api.github.com") throws {
        let (leaf, key) = try ca.leaf(for: host)
        let context = try NIOSSLContext(configuration: .makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: Array(try leaf.serializeAsPEM().pemString.utf8), format: .pem))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(key.pemRepresentation.utf8), format: .pem))))
        let heard = self.heard, bodies = self.bodies, headers = self.headers
        channel = try ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(Echo(heard: heard, bodies: bodies, headers: headers))
                }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
        port = channel.localAddress?.port ?? 0
    }

    var requests: [String] { heard.withLock { $0 } }

    func stop() { try? channel.close().wait() }

    final class Echo: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart
        let heard: Locked<[String]>
        let bodies: Locked<[Int]>
        let headers: Locked<[[String]]>
        var head: HTTPRequestHead?
        var length = 0

        init(heard: Locked<[String]>, bodies: Locked<[Int]>, headers: Locked<[[String]]>) {
            self.heard = heard
            self.bodies = bodies
            self.headers = headers
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let given):
                head = given
                length = 0
            case .body(let buffer): length += buffer.readableBytes
            case .end:
                guard let head else { return }
                let line = "\(head.method.rawValue) \(head.uri) \(head.headers["authorization"].first ?? "")"
                heard.withLock { $0.append(line) }
                let length = self.length
                bodies.withLock { $0.append(length) }
                headers.withLock { $0.append(head.headers.map { $0.name.lowercased() } + head.headers["accept-encoding"].map { "accept-encoding=\($0)" }) }
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

/// An answer, read whole: its status and its body.
private final class Collector: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    let promise: EventLoopPromise<(status: Int, body: [UInt8])>
    private var status = 0
    private var body: [UInt8] = []
    private var done = false

    init(promise: EventLoopPromise<(status: Int, body: [UInt8])>) { self.promise = promise }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): status = Int(head.status.code)
        case .body(let buffer): body += Array(buffer.readableBytesView)
        case .end:
            finish(.success((status, body)))
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(.failure(error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(.failure(ChannelError.eof))
        context.fireChannelInactive()
    }

    private func finish(_ result: Result<(status: Int, body: [UInt8]), Error>) {
        guard !done else { return }
        done = true
        promise.completeWith(result)
    }
}

final class GitHubInterceptorTests: XCTestCase {
    private static let relayToken = "relay-secret"
    private var group: MultiThreadedEventLoopGroup!
    private var github: EchoGitHub!
    private var interceptor: GitHubInterceptor!
    private var relay: RelayListener!
    private var port = 0
    private var proxyCA: AgentProxyCA!
    private var folder: URL!
    private var egress: EgressLog!
    private let lines = Lines()

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("github-interceptor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        egress = EgressLog(file: folder.appendingPathComponent("egress.log"))
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        proxyCA = try AgentProxyCA.make(now: Date())
        try launch()
    }

    /// GitHub played as `host`, and agent-proxy before it: its connections to
    /// it held back `delay`, or to nothing at all (`unreachable`).
    private func launch(host: String = "api.github.com", delay: TimeAmount = .zero, unreachable: Bool = false,
                        tokens: any GitHubTokenSource = FixedTokens(),
                        reader: @escaping @Sendable (String) -> any GitHubReading = { _ in DefaultBranchMain() }) throws {
        relay?.stop()
        interceptor?.stop()
        github?.stop()
        let githubCA = try AgentProxyCA.make(now: Date())
        github = try EchoGitHub(ca: githubCA, group: group, host: host)
        var trust = TLSConfiguration.makeClientConfiguration()
        trust.trustRoots = .certificates([try NIOSSLCertificate(bytes: Array(try githubCA.pem.utf8), format: .pem)])
        let githubPort = unreachable ? 1 : github.port
        let lines = self.lines
        interceptor = try GitHubInterceptor(gate: GitHubGate(), ca: proxyCA, tokens: tokens, reader: reader,
                                            upstream: .init(address: { _ in ("127.0.0.1", githubPort) }, tls: trust, delay: delay),
                                            egress: egress, log: { lines.add($0) })
        let proxy = EgressProxy(connect: { agent_proxy_connect_tcp($0.host, $0.port) }, interceptor: interceptor, egress: egress,
                                log: { lines.add($0) })
        relay = nil
        for _ in 0..<20 {
            let candidate = Int.random(in: 20000...45000)
            if let made = RelayListener(port: candidate, relayToken: { Self.relayToken }, proxy: proxy, log: { lines.add($0) }) {
                made.start()
                relay = made
                port = candidate
                break
            }
        }
        guard relay != nil else { throw XCTSkip("no port for the relay listener") }
    }

    override func tearDownWithError() throws {
        relay?.stop()
        interceptor?.stop()
        github?.stop()
        try group?.syncShutdownGracefully()
        try? FileManager.default.removeItem(at: folder)
    }

    /// A container's request to `host` through the relay: its CONNECT, then
    /// TLS trusting agent-proxy's authority, then the request, with gh's
    /// placeholder token (`authorization`). The answer's status and body.
    private func agent(_ method: HTTPMethod, _ path: String, host: String = "api.github.com", body: [UInt8] = [],
                       contentType: String = "application/json", authorization: String = "token placeholder", extraHeaders: [String] = [],
                       relayToken: String = GitHubInterceptorTests.relayToken) throws
        -> (status: Int, body: String) {
        let socket = agent_proxy_connect_tcp("127.0.0.1", UInt16(port))
        guard socket >= 0 else { throw XCTSkip("the relay listener can't be reached") }
        let connect = ProxyProtocolHeader.relayed(lease: "lease-7", relayToken: relayToken).encoded()
            + Array("CONNECT \(host):443 HTTP/1.1\r\nX-Agent-ID: 0B5E7A52-1C1B-4E2A-9C3D-5F6A7B8C9D0E\r\n\r\n".utf8)
        _ = connect.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
        // The CONNECT's answer, byte by byte: nothing of TLS's taken with it.
        agent_proxy_set_receive_timeout(socket, 10)
        var head: [UInt8] = []
        var byte: UInt8 = 0
        while !head.suffix(4).elementsEqual(Array("\r\n\r\n".utf8)) {
            guard read(socket, &byte, 1) == 1 else {
                close(socket)
                return (0, String(decoding: head, as: UTF8.self))
            }
            head.append(byte)
        }
        let answer = String(decoding: head, as: UTF8.self)
        guard answer.hasPrefix("HTTP/1.1 200 ") else {
            close(socket)
            return (0, answer)
        }
        var trust = TLSConfiguration.makeClientConfiguration()
        trust.trustRoots = .certificates([try NIOSSLCertificate(bytes: Array(try proxyCA.pem.utf8), format: .pem)])
        let context = try NIOSSLContext(configuration: trust)
        let promise = group.next().makePromise(of: (status: Int, body: [UInt8]).self)
        let channel = try ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(try NIOSSLClientHandler(context: context, serverHostname: host))
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                    try channel.pipeline.syncOperations.addHandler(Collector(promise: promise))
                }
            }
            .withConnectedSocket(socket)
            .wait()
        var headers = HTTPHeaders()
        headers.add(name: "host", value: host)
        headers.add(name: "authorization", value: authorization)
        headers.add(name: "content-length", value: "\(body.count)")
        if !body.isEmpty { headers.add(name: "content-type", value: contentType) }
        for header in extraHeaders {
            let parts = header.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            headers.add(name: parts[0], value: parts[1])
        }
        channel.write(HTTPClientRequestPart.head(HTTPRequestHead(version: .http1_1, method: method, uri: path, headers: headers)), promise: nil)
        if !body.isEmpty {
            var buffer = channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
        }
        channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(15)) { promise.fail(ChannelError.connectTimeout(.seconds(15))) }
        defer { timeout.cancel() }
        let got = try promise.futureResult.wait()
        try? channel.close().wait()
        return (got.status, String(decoding: got.body, as: UTF8.self))
    }

    private func json(_ text: String) -> [UInt8] { Array(text.utf8) }

    func testAReadGoesOnWithTheTokenWhichNeverComesBack() throws {
        let (status, body) = try agent(.GET, "/repos/AttilaTheFun/shireworks/pulls/3")
        XCTAssertEqual(status, 200, body)
        XCTAssertEqual(github.requests, ["GET /repos/AttilaTheFun/shireworks/pulls/3 Bearer ghs_fixedtoken"], "the placeholder replaced")
        XCTAssertTrue(body.contains("Bearer " + String(repeating: "*", count: "ghs_fixedtoken".count)), "masked on its way back: \(body)")
        XCTAssertFalse(body.contains("ghs_fixedtoken"))
    }

    func testARefusalIsGitHubsOwnFormAndNeverReachesGitHub() throws {
        let rest = try agent(.DELETE, "/repos/AttilaTheFun/shireworks/issues/comments/5")
        XCTAssertEqual(rest.status, 403, rest.body)
        XCTAssertTrue(rest.body.contains("\"message\":\"Refused:"), rest.body)
        let other = try agent(.POST, "/repos/someone/else/issues/3/comments", body: json(#"{"body":"x"}"#))
        XCTAssertEqual(other.status, 403, other.body)
        XCTAssertTrue(other.body.contains("not among the repositories"), other.body)
        XCTAssertEqual(github.requests, [], "nothing refused reached GitHub")
    }

    /// Logan (2026-11-14): merging a pull request, by REST or GraphQL, is
    /// refused in each client's form, and never reaches GitHub.
    func testAMergeIsRefusedInTheClientsForm() throws {
        let sha = String(repeating: "a", count: 40)
        let rest = try agent(.PUT, "/repos/AttilaTheFun/shireworks/pulls/3/merge", body: json("{\"merge_method\":\"squash\",\"sha\":\"\(sha)\"}"))
        XCTAssertEqual(rest.status, 403, rest.body)
        XCTAssertTrue(rest.body.contains("\"message\":\"Refused: merging pull requests is Logan's alone"), rest.body)
        let graphQL = try agent(.POST, "/graphql", body: json(
            #"{"query":"mutation PullRequestMerge($input:MergePullRequestInput!){mergePullRequest(input:$input){clientMutationId}}","variables":{"input":{"pullRequestId":"PR_1","mergeMethod":"SQUASH"}}}"#))
        XCTAssertEqual(graphQL.status, 200, "GraphQL's errors are a 200's: \(graphQL.body)")
        XCTAssertTrue(graphQL.body.contains("\"type\":\"FORBIDDEN\""), graphQL.body)
        XCTAssertTrue(graphQL.body.contains("Refused: merging pull requests is Logan's alone, never an agent's (mergePullRequest)"), graphQL.body)
        let auto = try agent(.POST, "/graphql", body: json(#"{"query":"mutation { enablePullRequestAutoMerge(input: {pullRequestId: \"PR_1\"}) { clientMutationId } }"}"#))
        XCTAssertTrue(auto.body.contains("Refused: merging pull requests is Logan's alone, never an agent's (enablePullRequestAutoMerge)"), auto.body)
        XCTAssertEqual(github.requests, [])
    }

    /// Logan (2026-11-25): agents may close pull requests and issues they
    /// opened themselves. With the App's token, its bot's own close over
    /// REST and GraphQL, read first with the token the close goes on with;
    /// Logan's are refused and never reach GitHub; reopening is refused.
    func testAnAgentClosesWhatItsBotOpenedAndNothingElse() throws {
        let reads = Locked<[String]>([])
        try launch(tokens: AppTokens(), reader: { token in Authors(token: token, reads: reads) })
        let closed = json(#"{"state":"closed"}"#)
        func closing(_ mutation: String, _ input: String) -> [UInt8] {
            json(#"{"query":"mutation($input:\#(mutation == "closeIssue" ? "CloseIssueInput" : "ClosePullRequestInput")!){\#(mutation)(input:$input){clientMutationId}}","variables":{"input":\#(input)}}"#)
        }
        // The bot's own pull request and issue, by REST and by GraphQL.
        for path in ["/repos/AttilaTheFun/shireworks/pulls/3", "/repos/AttilaTheFun/shireworks/issues/4"] {
            let own = try agent(.PATCH, path, body: closed)
            XCTAssertEqual(own.status, 200, own.body)
        }
        for (mutation, input) in [("closePullRequest", #"{"pullRequestId":"PR_bot"}"#), ("closeIssue", #"{"issueId":"I_bot","stateReason":"COMPLETED"}"#)] {
            let own = try agent(.POST, "/graphql", body: closing(mutation, input))
            XCTAssertEqual(own.status, 200, own.body)
            XCTAssertFalse(own.body.contains("FORBIDDEN"), own.body)
        }
        XCTAssertEqual(github.requests, ["PATCH /repos/AttilaTheFun/shireworks/pulls/3 Bearer ghs_fixedtoken",
                                         "PATCH /repos/AttilaTheFun/shireworks/issues/4 Bearer ghs_fixedtoken",
                                         "POST /graphql Bearer ghs_fixedtoken", "POST /graphql Bearer ghs_fixedtoken"])
        // Read first, with the token the close went on with.
        XCTAssertEqual(reads.withLock { $0 }, ["GET /repos/AttilaTheFun/shireworks/issues/3 ghs_fixedtoken",
                                               "GET /repos/AttilaTheFun/shireworks/issues/4 ghs_fixedtoken",
                                               "graphql PR_bot ghs_fixedtoken", "graphql I_bot ghs_fixedtoken"])

        // Logan's: refused, and never at GitHub.
        for path in ["/repos/AttilaTheFun/shireworks/pulls/5", "/repos/AttilaTheFun/shireworks/issues/6"] {
            let logans = try agent(.PATCH, path, body: closed)
            XCTAssertEqual(logans.status, 403, logans.body)
            XCTAssertTrue(logans.body.contains("is AttilaTheFun's: an agent closes only what it opened itself (logan-shire-agent[bot]'s)"), logans.body)
        }
        for (mutation, input) in [("closePullRequest", #"{"pullRequestId":"PR_logan"}"#), ("closeIssue", #"{"issueId":"I_logan"}"#)] {
            let logans = try agent(.POST, "/graphql", body: closing(mutation, input))
            XCTAssertEqual(logans.status, 200, "GraphQL's errors are a 200's: \(logans.body)")
            XCTAssertTrue(logans.body.contains("\"type\":\"FORBIDDEN\""), logans.body)
            XCTAssertTrue(logans.body.contains("is AttilaTheFun's"), logans.body)
        }
        // Reopening, its own included: refused before any read.
        let readsBefore = reads.withLock { $0.count }
        let reopened = try agent(.PATCH, "/repos/AttilaTheFun/shireworks/pulls/3", body: json(#"{"state":"open"}"#))
        XCTAssertEqual(reopened.status, 403, reopened.body)
        XCTAssertTrue(reopened.body.contains("reopening an issue or a pull request is Logan's alone"), reopened.body)
        for mutation in ["reopenPullRequest(input: {pullRequestId: \\\"PR_bot\\\"})", "reopenIssue(input: {issueId: \\\"I_bot\\\"})"] {
            let again = try agent(.POST, "/graphql", body: json(#"{"query":"mutation { \#(mutation) { clientMutationId } }"}"#))
            XCTAssertTrue(again.body.contains("\"type\":\"FORBIDDEN\""), again.body)
            XCTAssertTrue(again.body.contains("reopening an issue or a pull request is Logan's alone"), again.body)
        }
        XCTAssertEqual(reads.withLock { $0.count }, readsBefore, "a reopen is refused before anything is read")
        XCTAssertEqual(github.requests.count, 4, "nothing refused reached GitHub: \(github.requests)")
    }

    /// With the auth token (no App), the bot is unknown: every close is
    /// refused, saying why, and nothing is read or reaches GitHub.
    func testWithoutTheAppClosingIsRefused() throws {
        let reads = Locked<[String]>([])
        try launch(tokens: FixedTokens(), reader: { token in Authors(token: token, reads: reads) })
        let rest = try agent(.PATCH, "/repos/AttilaTheFun/shireworks/pulls/3", body: json(#"{"state":"closed"}"#))
        XCTAssertEqual(rest.status, 403, rest.body)
        XCTAssertTrue(rest.body.contains("with no GitHub App (github-app/key and github-app/id) or its bot not found, closing is Logan's"), rest.body)
        let graphQL = try agent(.POST, "/graphql", body: json(
            #"{"query":"mutation($input:CloseIssueInput!){closeIssue(input:$input){clientMutationId}}","variables":{"input":{"issueId":"I_bot"}}}"#))
        XCTAssertTrue(graphQL.body.contains("\"type\":\"FORBIDDEN\""), graphQL.body)
        XCTAssertTrue(graphQL.body.contains("with no GitHub App"), graphQL.body)
        XCTAssertEqual(reads.withLock { $0 }, [])
        XCTAssertEqual(github.requests, [])
    }

    /// Logan (2026-11-14): publishing a release is refused, as gh shows REST's.
    func testPublishingAReleaseIsRefusedInTheClientsForm() throws {
        let edit = try agent(.PATCH, "/repos/AttilaTheFun/shireworks/releases/9", body: json(#"{"draft":false}"#))
        XCTAssertEqual(edit.status, 403, edit.body)
        XCTAssertTrue(edit.body.contains("Refused: publishing a release is Logan's alone"), edit.body)
        let made = try agent(.POST, "/repos/AttilaTheFun/shireworks/releases", body: json(#"{"tag_name":"v1.0","draft":false}"#))
        XCTAssertEqual(made.status, 403, made.body)
        XCTAssertTrue(made.body.contains("Refused: publishing a release is Logan's alone"), made.body)
        XCTAssertEqual(github.requests, [])
    }

    /// Logan (2026-11-14): deleting a ref is refused: REST's 403, GraphQL's
    /// errors, and git's report-status, the ref turned down in side-band.
    func testDeletingARefIsRefusedInEachClientsForm() throws {
        let rest = try agent(.DELETE, "/repos/AttilaTheFun/shireworks/git/refs/heads/feature")
        XCTAssertEqual(rest.status, 403, rest.body)
        XCTAssertTrue(rest.body.contains("Refused: deleting a branch or any other ref is Logan's alone"), rest.body)
        let graphQL = try agent(.POST, "/graphql", body: json(#"{"query":"mutation { deleteRef(input: {refId: \"R\"}) { clientMutationId } }"}"#))
        XCTAssertEqual(graphQL.status, 200, graphQL.body)
        XCTAssertTrue(graphQL.body.contains("\"type\":\"FORBIDDEN\""), graphQL.body)
        XCTAssertTrue(graphQL.body.contains("deleting a branch or any other ref"), graphQL.body)
        let zero = String(repeating: "0", count: 40), sha = String(repeating: "a", count: 40)
        let line = "\(sha) \(zero) refs/heads/feature\0report-status side-band-64k\n"
        let push = try agent(.POST, "/AttilaTheFun/shireworks.git/git-receive-pack", host: "github.com",
                             body: Array((String(format: "%04x", line.utf8.count + 4) + line + "0000").utf8),
                             contentType: "application/x-git-receive-pack-request")
        XCTAssertEqual(push.status, 200, push.body)
        XCTAssertTrue(push.body.contains("ng refs/heads/feature Refused: deleting a branch or any other ref is Logan's alone"), push.body)
        XCTAssertEqual(github.requests, [])
    }


    /// A push's command list, then its pack, as git sends it.
    private func push(_ line: String, pack: Int) -> [UInt8] {
        let commands = "\(line)\0report-status side-band-64k\n"
        return Array((String(format: "%04x", commands.utf8.count + 4) + commands + "0000PACK").utf8)
            + (0..<pack).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
    }

    /// NCH's review of #417: what of a body comes while GitHub's connection
    /// is still being made is kept, and sent on whole and in order once it
    /// is: a push of several megabytes, decided by its commands while its
    /// pack is still coming, and one whose end came before the connection.
    func testABodyThatComesWhileGitHubIsReachedArrivesWhole() throws {
        try launch(host: "github.com", delay: .milliseconds(700))
        let zero = String(repeating: "0", count: 40), sha = String(repeating: "a", count: 40)
        let big = push("\(zero) \(sha) refs/heads/feature", pack: 3 << 20)
        let large = try agent(.POST, "/AttilaTheFun/shireworks.git/git-receive-pack", host: "github.com", body: big,
                              contentType: "application/x-git-receive-pack-request")
        XCTAssertEqual(large.status, 200, large.body)
        let small = push("\(zero) \(sha) refs/heads/other", pack: 100)
        let quick = try agent(.POST, "/AttilaTheFun/shireworks.git/git-receive-pack", host: "github.com", body: small,
                              contentType: "application/x-git-receive-pack-request")
        XCTAssertEqual(quick.status, 200, quick.body)
        XCTAssertEqual(github.bodies.withLock { $0 }, [big.count, small.count], "each body whole")
        XCTAssertEqual(github.requests.map { $0.split(separator: " ").prefix(2).joined(separator: " ") },
                       ["POST /AttilaTheFun/shireworks.git/git-receive-pack", "POST /AttilaTheFun/shireworks.git/git-receive-pack"])
    }

    /// NCH's follow-up to #417: while a request is decided and GitHub's
    /// connection made, the client's stream isn't read, so what is held then
    /// stays bounded: a push larger than the bound (8 MiB) still arrives
    /// whole, never refused for its size.
    func testABodyLargerThanTheBoundIsHeldBackNotHeld() throws {
        try launch(host: "github.com", delay: .milliseconds(700))
        let zero = String(repeating: "0", count: 40), sha = String(repeating: "a", count: 40)
        let big = push("\(zero) \(sha) refs/heads/feature", pack: 12 << 20)
        let answer = try agent(.POST, "/AttilaTheFun/shireworks.git/git-receive-pack", host: "github.com", body: big,
                               contentType: "application/x-git-receive-pack-request")
        XCTAssertEqual(answer.status, 200, answer.body)
        XCTAssertEqual(github.bodies.withLock { $0 }, [big.count], "whole, though more than the bound came while it was decided")
    }

    /// A body past the bound, should one be held all the same, is refused
    /// 413 in its client's form: REST's JSON, plain text on github.com.
    func testATooLargeRefusalIsTheClientsForm() {
        let (rest, restBody) = GitHubInterceptor.refusal("too much", failed: false, tooLarge: true, method: .POST, host: "api.github.com",
                                                         uri: "/repos/a/b/issues", body: nil)
        XCTAssertEqual(rest.status, .payloadTooLarge)
        XCTAssertTrue(String(decoding: restBody, as: UTF8.self).contains("\"message\":\"Refused: too much\""))
        let (plain, _) = GitHubInterceptor.refusal("too much", failed: false, tooLarge: true, method: .POST, host: "github.com",
                                                   uri: "/a/b.git/git-upload-pack", body: nil)
        XCTAssertEqual(plain.status, .payloadTooLarge)
        let (graphQL, _) = GitHubInterceptor.refusal("too much", failed: false, tooLarge: true, method: .POST, host: "api.github.com",
                                                     uri: "/graphql", body: nil)
        XCTAssertEqual(graphQL.status, .ok, "GraphQL's errors are a 200's")
        XCTAssertEqual(GitHubInterceptor.RequestHandler.waitingLimit, 8 << 20)
    }

    /// GitHub that can't be reached while the body is still coming: a
    /// failure in git's form, and nothing more of the body read.
    func testAConnectionThatFailsWhileTheBodyComesIsAFailure() throws {
        try launch(host: "github.com", unreachable: true)
        let zero = String(repeating: "0", count: 40), sha = String(repeating: "a", count: 40)
        let answer = try agent(.POST, "/AttilaTheFun/shireworks.git/git-receive-pack", host: "github.com",
                               body: push("\(zero) \(sha) refs/heads/feature", pack: 1 << 20), contentType: "application/x-git-receive-pack-request")
        XCTAssertTrue(answer.body.contains("Failed: GitHub can't be reached"), "\(answer.status) \(answer.body)")
    }

    /// What goes on to GitHub: no header that would change its method, and
    /// its answer asked for in plain bytes, so a token in it can be masked.
    func testMethodOverridesAreDroppedAndTheAnswerIsAskedForPlain() throws {
        let headers = ["X-HTTP-Method-Override: DELETE", "X-HTTP-Method: DELETE", "X-Method-Override: DELETE", "Accept-Encoding: gzip"]
        let (status, body) = try agent(.GET, "/repos/AttilaTheFun/shireworks/pulls/3", extraHeaders: headers)
        XCTAssertEqual(status, 200, body)
        let sent = try XCTUnwrap(github.headers.withLock { $0.first })
        for name in ["x-http-method-override", "x-http-method", "x-method-override"] { XCTAssertFalse(sent.contains(name), "\(name): \(sent)") }
        XCTAssertTrue(sent.contains("accept-encoding=identity"), "\(sent)")
        XCTAssertFalse(sent.contains("accept-encoding=gzip"), "\(sent)")
    }

    /// The token masked wherever GitHub's answer has it: split across the
    /// body's pieces, or in a header.
    func testTheTokenIsMaskedAcrossPiecesAndInHeaders() {
        let token = "ghs_fixedtoken"
        let text = "a ghs_fixedtoken b ghs_fixedtoken"
        for cut in 1..<text.utf8.count {
            var scrubber = GitHubInterceptor.Scrubber(token: token)
            let bytes = Array(text.utf8)
            let out = scrubber.pass(Array(bytes[..<cut])) + scrubber.pass(Array(bytes[cut...])) + scrubber.finish()
            XCTAssertEqual(String(decoding: out, as: UTF8.self), "a ************** b **************", "cut at \(cut)")
        }
        var byteByByte = GitHubInterceptor.Scrubber(token: token)
        let out = Array(text.utf8).flatMap { byteByByte.pass([$0]) } + byteByByte.finish()
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "a ************** b **************")
        var headers = HTTPHeaders()
        headers.add(name: "Location", value: "https://example.com/?t=ghs_fixedtoken")
        headers.add(name: "X-Other", value: "plain")
        let scrubbed = GitHubInterceptor.scrubbed(headers, token)
        XCTAssertEqual(scrubbed["location"].first, "https://example.com/?t=**************")
        XCTAssertEqual(scrubbed["x-other"].first, "plain")
    }

    /// Logan, 9 Nov 2026: a read of a repository outside the allowed ones
    /// goes on with no authorization at all: neither the token nor the
    /// client's placeholder reaches GitHub.
    func testAReadOutsideTheAllowedRepositoriesGoesOnWithNoToken() throws {
        let (status, body) = try agent(.GET, "/repos/swiftlang/swift-foundation/tags")
        XCTAssertEqual(status, 200, body)
        XCTAssertEqual(github.requests, ["GET /repos/swiftlang/swift-foundation/tags "], "no authorization header")
        XCTAssertFalse(body.contains("ghs_fixedtoken"))
        XCTAssertFalse(body.contains("placeholder"))
        _ = try agent(.GET, "/repos/AttilaTheFun/shireworks/pulls/3")
        XCTAssertEqual(github.requests.last, "GET /repos/AttilaTheFun/shireworks/pulls/3 Bearer ghs_fixedtoken")
    }

    /// Logan's container test (25 Nov 2026): with no auth token configured, a
    /// clone of an allowed public repository failed at once. Now a fetch, a
    /// clone and a download of an allowed repository go on anonymously, as a
    /// read outside them does (Logan, 9 Nov 2026), with no authorization at
    /// all; a push is still refused, saying where the token is set, and none
    /// of it reaches GitHub.
    func testWithNoTokenAnAllowedRepositoryIsClonedAnonymouslyAndNeverPushed() throws {
        try launch(host: "github.com", tokens: ConfiguredGitHubToken(current: { nil }))
        let refs = try agent(.GET, "/AttilaTheFun/swift_sql.git/info/refs?service=git-upload-pack", host: "github.com")
        XCTAssertEqual(refs.status, 200, refs.body)
        let pack = try agent(.POST, "/AttilaTheFun/swift_sql.git/git-upload-pack", host: "github.com", body: Array("0000".utf8),
                             contentType: "application/x-git-upload-pack-request",
                             authorization: "Basic " + Data("x-access-token:visor-agent-proxy".utf8).base64EncodedString())
        XCTAssertEqual(pack.status, 200, pack.body)
        let archive = try agent(.GET, "/AttilaTheFun/swift_sql/archive/refs/tags/v1.0.0.tar.gz", host: "github.com")
        XCTAssertEqual(archive.status, 200, archive.body)
        XCTAssertEqual(github.requests, ["GET /AttilaTheFun/swift_sql.git/info/refs?service=git-upload-pack ",
                                         "POST /AttilaTheFun/swift_sql.git/git-upload-pack ",
                                         "GET /AttilaTheFun/swift_sql/archive/refs/tags/v1.0.0.tar.gz "], "no authorization header")
        XCTAssertFalse(github.headers.withLock { $0 }.contains { $0.contains("authorization") }, "the client's placeholder taken off")
        // A push: its discovery and its commands, refused in git's form.
        let discovery = try agent(.GET, "/AttilaTheFun/swift_sql.git/info/refs?service=git-receive-pack", host: "github.com")
        XCTAssertTrue(discovery.body.contains("ERR Failed: agent-proxy has no auth token for GitHub"), discovery.body)
        let zero = String(repeating: "0", count: 40), sha = String(repeating: "a", count: 40)
        let pushed = try agent(.POST, "/AttilaTheFun/swift_sql.git/git-receive-pack", host: "github.com",
                               body: push("\(zero) \(sha) refs/heads/feature", pack: 100), contentType: "application/x-git-receive-pack-request")
        XCTAssertTrue(pushed.body.contains("ng refs/heads/feature Failed: agent-proxy has no auth token for GitHub"), pushed.body)
        XCTAssertTrue(pushed.body.contains("secret-set github-token"), pushed.body)
        XCTAssertEqual(github.requests.count, 3, "no push reached GitHub")
        let decisions = egress.entries().filter { $0.method != nil }.map { "\($0.method ?? "") \($0.decision ?? "") \($0.outcome)" }
        XCTAssertEqual(decisions, ["GET anonymous forwarded", "POST anonymous forwarded", "GET anonymous forwarded",
                                   "GET allow unreachable", "POST check unreachable"], "logged as anonymous")
    }

    /// The same for REST and GraphQL with no token configured: gh's reads
    /// (GET, a query) go on anonymously, its `token visor-agent-proxy` taken
    /// off; its writes (a comment, a mutation) are refused, saying where the
    /// token is set.
    func testWithNoTokenGhsReadsGoOnAnonymouslyAndItsWritesAreRefused() throws {
        try launch(tokens: ConfiguredGitHubToken(current: { nil }))
        let placeholder = "token visor-agent-proxy"
        let pulls = try agent(.GET, "/repos/AttilaTheFun/swift_sql/pulls?state=open", authorization: placeholder)
        XCTAssertEqual(pulls.status, 200, pulls.body)
        let query = try agent(.POST, "/graphql", body: json(#"{"query":"query { repository(owner: \"AttilaTheFun\", name: \"swift_sql\") { name } }"}"#),
                              authorization: placeholder)
        XCTAssertEqual(query.status, 200, query.body)
        XCTAssertEqual(github.requests, ["GET /repos/AttilaTheFun/swift_sql/pulls?state=open ", "POST /graphql "], "no authorization header")
        XCTAssertFalse(github.headers.withLock { $0 }.contains { $0.contains("authorization") })
        XCTAssertFalse(pulls.body.contains("visor-agent-proxy") || query.body.contains("visor-agent-proxy"), "the placeholder never reached GitHub")
        let comment = try agent(.POST, "/repos/AttilaTheFun/swift_sql/issues/3/comments", body: json(#"{"body":"x"}"#), authorization: placeholder)
        XCTAssertEqual(comment.status, 502, comment.body)
        XCTAssertTrue(comment.body.contains("Failed: agent-proxy has no auth token for GitHub"), comment.body)
        let mutation = try agent(.POST, "/graphql", body: json(#"{"query":"mutation { addComment(input: {subjectId: \"I_1\", body: \"x\"}) { clientMutationId } }"}"#),
                                 authorization: placeholder)
        XCTAssertEqual(mutation.status, 200, "GraphQL's errors are a 200's: \(mutation.body)")
        XCTAssertTrue(mutation.body.contains("\"type\":\"FORBIDDEN\""), mutation.body)
        XCTAssertTrue(mutation.body.contains("secret-set github-token"), mutation.body)
        XCTAssertEqual(github.requests.count, 2, "no write reached GitHub")
        let decisions = egress.entries().filter { $0.method != nil }.map { "\($0.method ?? "") \($0.decision ?? "") \($0.outcome)" }
        XCTAssertEqual(decisions, ["GET anonymous forwarded", "POST anonymous forwarded", "POST allow unreachable", "POST check unreachable"])
    }

    /// With a token, gh's placeholder is replaced by it, whichever way it
    /// came (`token …` or `Bearer …`): one authorization header, the proxy's.
    func testWithATokenGhsPlaceholderIsReplaced() throws {
        for placeholder in ["token visor-agent-proxy", "Bearer visor-agent-proxy"] {
            _ = try agent(.GET, "/repos/AttilaTheFun/swift_sql/pulls", authorization: placeholder)
        }
        let query = try agent(.POST, "/graphql", body: json(#"{"query":"{ viewer { login } }"}"#), authorization: "token visor-agent-proxy")
        XCTAssertEqual(query.status, 200, query.body)
        XCTAssertEqual(github.requests, ["GET /repos/AttilaTheFun/swift_sql/pulls Bearer ghs_fixedtoken",
                                         "GET /repos/AttilaTheFun/swift_sql/pulls Bearer ghs_fixedtoken",
                                         "POST /graphql Bearer ghs_fixedtoken"])
        XCTAssertTrue(github.headers.withLock { $0 }.allSatisfy { $0.filter { $0 == "authorization" }.count == 1 }, "the proxy's alone")
        let decisions = egress.entries().filter { $0.method != nil }.map(\.decision)
        XCTAssertEqual(decisions, ["allow", "allow", "allow"])
    }

    /// Only a token that isn't configured lets a read go on anonymously: one
    /// that can't be had otherwise (an App's that couldn't be minted) is a
    /// failure, and nothing reaches GitHub.
    func testATokenThatCantBeHadIsNoReasonToGoAnonymously() throws {
        try launch(tokens: BrokenTokens())
        let (status, body) = try agent(.GET, "/repos/AttilaTheFun/swift_sql/pulls")
        XCTAssertEqual(status, 502, body)
        XCTAssertTrue(body.contains("Failed: the token couldn't be made"), body)
        XCTAssertEqual(github.requests, [])
    }

    func testAnAllowedWriteGoesOnWithItsBody() throws {
        let (status, body) = try agent(.POST, "/repos/AttilaTheFun/shireworks/issues/3/comments", body: json(#"{"body":"Looks right"}"#))
        XCTAssertEqual(status, 200, body)
        XCTAssertEqual(github.requests, ["POST /repos/AttilaTheFun/shireworks/issues/3/comments Bearer ghs_fixedtoken"])
    }

    /// A push to main, refused as git reads a push's answer: report-status,
    /// the ref turned down, in side-band as asked.
    func testAPushToMainIsTurnedDownAsGitShowsIt() throws {
        let zero = String(repeating: "0", count: 40), sha = String(repeating: "a", count: 40)
        let line = "\(zero) \(sha) refs/heads/main\0report-status side-band-64k\n"
        let (status, answer) = try agent(.POST, "/AttilaTheFun/shireworks.git/git-receive-pack", host: "github.com",
                                         body: Array((String(format: "%04x", line.utf8.count + 4) + line + "0000PACK").utf8),
                                         contentType: "application/x-git-receive-pack-request")
        XCTAssertEqual(status, 200, answer)
        XCTAssertTrue(answer.contains("ng refs/heads/main Refused: main is never pushed"), answer)
        XCTAssertEqual(github.requests, [])
    }

    /// Each request is a line of the egress log (route `github`): its
    /// method, its path's class and the gate's decision, never its body, a
    /// header or the token.
    func testEachRequestIsLoggedWithItsDecisionAndNothingOfItsContents() throws {
        _ = try agent(.GET, "/repos/AttilaTheFun/shireworks/pulls/3?per_page=5")
        _ = try agent(.PUT, "/repos/AttilaTheFun/shireworks/pulls/3/merge", body: json(#"{"merge_method":"squash","commit_message":"a secret body"}"#))
        _ = try agent(.GET, "/repos/swiftlang/swift-foundation/tags")
        let entries = egress.entries().filter { $0.method != nil }
        XCTAssertEqual(entries.map { "\($0.host) \($0.route.rawValue) \($0.method ?? "") \($0.pathClass ?? "") \($0.decision ?? "") \($0.outcome)" }, [
            "api.github.com github GET /repos/AttilaTheFun/shireworks/pulls/{n} allow forwarded",
            "api.github.com github PUT /repos/AttilaTheFun/shireworks/pulls/{n}/merge refuse refused",
            "api.github.com github GET /repos/swiftlang/swift-foundation/tags anonymous forwarded",
        ])
        XCTAssertTrue(entries.allSatisfy { $0.lease == "lease-7" && $0.agentClaimed == "0b5e7a52-1c1b-4e2a-9c3d-5f6a7b8c9d0e" })
        XCTAssertEqual(egress.entries().filter { $0.method == nil }.map(\.outcome), [.opened, .opened, .opened], "each CONNECT, opened")
        let text = try String(contentsOf: egress.file, encoding: .utf8)
        for secret in ["ghs_fixedtoken", "placeholder", "a secret body", "per_page", "authorization"] {
            XCTAssertFalse(text.lowercased().contains(secret.lowercased()), "\(secret) in the egress log")
        }
        XCTAssertFalse(lines.all.contains { $0.contains("ghs_fixedtoken") || $0.contains("placeholder") }, "\(lines.all)")
    }

    /// A stream without the relay's token is closed before its CONNECT is
    /// answered: nothing is opened, nothing reaches GitHub.
    func testOnlyTheRelaysStreamsAreLetIn() throws {
        let (status, answer) = try agent(.GET, "/repos/AttilaTheFun/shireworks/pulls", relayToken: "stranger")
        XCTAssertEqual(status, 0, answer)
        XCTAssertEqual(answer, "")
        XCTAssertEqual(github.requests, [])
    }

    /// Another host, or GitHub's on another port, is a tunnel as ever.
    func testOnlyGitHubsHostsOnPort443AreOpened() {
        XCTAssertTrue(interceptor.intercepts(.init(host: "API.github.com", port: 443)))
        XCTAssertTrue(interceptor.intercepts(.init(host: "uploads.github.com", port: 443)))
        XCTAssertFalse(interceptor.intercepts(.init(host: "github.com", port: 22)))
        XCTAssertFalse(interceptor.intercepts(.init(host: "objects.githubusercontent.com", port: 443)))
        XCTAssertFalse(interceptor.intercepts(.init(host: "evilgithub.com", port: 443)))
    }

    /// The host's way to it: the authority made in its secrets (a test's
    /// here) and its certificate written; made without the auth token too,
    /// what needs one then refused; none for a gate.json that isn't one.
    func testTheHostMakesItFromItsSecretsAndWritesTheCertificate() throws {
        let secrets = MemoryProxySecrets()
        let path = folder.appendingPathComponent("support/agent-proxy/ca.pem").path
        let lines = Lines()
        let tokenless = GitHubInterceptor.make(secrets: secrets, caCertificate: path, gateRules: nil, token: { nil }, egress: nil,
                                               log: { lines.add($0) })
        XCTAssertNotNil(tokenless)
        tokenless?.stop()
        XCTAssertTrue(lines.all.contains { $0.contains("no auth token yet") }, "\(lines.all)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the certificate is written")
        let ca = try AgentProxyCA.kept(in: secrets)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), try ca.pem, "the authority kept, not made again")
        let made = GitHubInterceptor.make(secrets: secrets, caCertificate: path, gateRules: nil, token: { "github_pat_x" }, egress: nil,
                                          log: { lines.add($0) })
        XCTAssertNotNil(made)
        made?.stop()
        XCTAssertTrue(lines.all.last?.contains("with the auth token") == true, "\(lines.all)")
        let badRules = folder.appendingPathComponent("gate.json")
        try Data("{}".utf8).write(to: badRules)
        XCTAssertNil(GitHubInterceptor.make(secrets: secrets, caCertificate: path, gateRules: badRules.path, token: { "t" }, egress: nil,
                                            log: { lines.add($0) }))
        XCTAssertTrue(lines.all.contains { $0.contains("isn't a gate.json") }, "\(lines.all)")
    }

    /// Settings' auth token, as kept now: trimmed, and none (nil or empty)
    /// refused, saying where it's set.
    func testTheConfiguredTokenIsSettingsAsKeptNow() async throws {
        let kept = Locked<String?>(nil)
        let source = ConfiguredGitHubToken(current: { kept.withLock { $0 } })
        do {
            _ = try await source.token(session: "s", repository: "o/r")
            XCTFail("no token: refused")
        } catch {
            XCTAssertTrue("\(error)".contains("secret-set github-token"), "\(error)")
        }
        kept.withLock { $0 = "  \n" }
        let blank: String? = try? await source.token(session: "s", repository: "o/r")
        XCTAssertNil(blank, "a blank one is none")
        kept.withLock { $0 = "github_pat_1\n" }
        let first = try await source.token(session: "s", repository: "o/r")
        XCTAssertEqual(first, "github_pat_1")
        kept.withLock { $0 = "github_pat_2" }
        await source.forget(session: "s", repository: "o/r")
        let second = try await source.token(session: "s", repository: "o/r")
        XCTAssertEqual(second, "github_pat_2", "a new one taken at once")
    }
}
