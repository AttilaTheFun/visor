// Claude's credential through agent-proxy end to end (docs/containers.md,
// "Claude's credential"): a container's stream through the relay listener,
// its CONNECT to api.anthropic.com opened with agent-proxy's Anthropic
// authority, and its requests over TLS, as Claude Code sends them with its
// placeholder (`CLAUDE_CODE_OAUTH_TOKEN=visor-agent-proxy`), to a stand-in
// for Anthropic. Each goes on with the credential kept in place of whatever
// the agent sent as `Authorization` or `x-api-key`, `oauth-2025-04-20`
// merged into `anthropic-beta`; the credential never comes back, nor into
// the egress log; and with none kept each is answered 401, saying where to
// sign in, and never reaches Anthropic.

import CAgentProxyPOSIX
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
@testable import VisorAgentProxy
import XCTest

/// Anthropic played over TLS: it answers each request with the headers it
/// came with (`authorization`, `x-api-key`, `anthropic-beta`), as JSON, and
/// keeps them.
private final class EchoAnthropic: Sendable {
    let port: Int
    let heard = Locked<[[String: String]]>([])
    private let channel: Channel

    init(ca: AgentProxyCA, group: EventLoopGroup) throws {
        let (leaf, key) = try ca.leaf(for: AnthropicInterceptor.host)
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

    var requests: [[String: String]] { heard.withLock { $0 } }

    func stop() { try? channel.close().wait() }

    final class Echo: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart
        let heard: Locked<[[String: String]]>
        var head: HTTPRequestHead?
        var length = 0

        init(heard: Locked<[[String: String]]>) { self.heard = heard }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let given):
                head = given
                length = 0
            case .body(let buffer): length += buffer.readableBytes
            case .end:
                guard let head else { return }
                var seen: [String: String] = ["request": "\(head.method.rawValue) \(head.uri)", "body": "\(length)"]
                for name in ["authorization", "x-api-key", "anthropic-beta", "host"] {
                    let values = head.headers[name]
                    if !values.isEmpty { seen[name] = values.joined(separator: "|") }
                }
                heard.withLock { $0.append(seen) }
                let body = Array((try? JSONSerialization.data(withJSONObject: seen, options: [.sortedKeys])) ?? Data())
                var headers = HTTPHeaders()
                headers.add(name: "content-type", value: "application/json")
                headers.add(name: "content-length", value: "\(body.count)")
                // An answer that echoes the credential in a header too.
                headers.add(name: "x-echo", value: seen["authorization"] ?? "")
                context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
                var buffer = context.channel.allocator.buffer(capacity: body.count)
                buffer.writeBytes(body)
                context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}

/// An answer, read whole: its status, headers and body.
private final class Collector: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    let promise: EventLoopPromise<(status: Int, headers: [String], body: [UInt8])>
    private var status = 0
    private var headers: [String] = []
    private var body: [UInt8] = []
    private var done = false

    init(promise: EventLoopPromise<(status: Int, headers: [String], body: [UInt8])>) { self.promise = promise }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            status = Int(head.status.code)
            headers = head.headers.map { "\($0.name): \($0.value)" }
        case .body(let buffer): body += Array(buffer.readableBytesView)
        case .end:
            finish(.success((status, headers, body)))
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

    private func finish(_ result: Result<(status: Int, headers: [String], body: [UInt8]), Error>) {
        guard !done else { return }
        done = true
        promise.completeWith(result)
    }
}

final class AnthropicInterceptorTests: XCTestCase {
    private static let relayToken = "relay-secret"
    private static let credential = "sk-ant-oat01-" + String(repeating: "Zq9_", count: 20)
    private var group: MultiThreadedEventLoopGroup!
    private var anthropic: EchoAnthropic!
    private var interceptor: AnthropicInterceptor!
    private var relay: RelayListener!
    private var port = 0
    private var proxyCA: AgentProxyCA!
    private var folder: URL!
    private var egress: EgressLog!
    private let lines = Lines()
    /// The credential as kept now.
    private let kept = Locked<String?>(AnthropicInterceptorTests.credential)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("anthropic-interceptor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        egress = EgressLog(file: folder.appendingPathComponent("egress.log"))
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        proxyCA = try AgentProxyCA.make(now: Date(), scope: .anthropic)
        let upstreamCA = try AgentProxyCA.make(now: Date(), scope: .anthropic)
        anthropic = try EchoAnthropic(ca: upstreamCA, group: group)
        var trust = TLSConfiguration.makeClientConfiguration()
        trust.trustRoots = .certificates([try NIOSSLCertificate(bytes: Array(try upstreamCA.pem.utf8), format: .pem)])
        let upstreamPort = anthropic.port
        let lines = self.lines
        let kept = self.kept
        interceptor = try AnthropicInterceptor(ca: proxyCA, token: { kept.withLock { $0 } },
                                               upstream: .init(address: { _ in ("127.0.0.1", upstreamPort) }, tls: trust),
                                               egress: egress, log: { lines.add($0) })
        let proxy = EgressProxy(connect: { agent_proxy_connect_tcp($0.host, $0.port) }, interceptor: Interceptors([interceptor]),
                                egress: egress, log: { lines.add($0) })
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
        anthropic?.stop()
        try group?.syncShutdownGracefully()
        try? FileManager.default.removeItem(at: folder)
    }

    /// A container's request through the relay, as Claude Code sends it: its
    /// CONNECT, TLS trusting agent-proxy's Anthropic authority, then the
    /// request with the placeholder and `headers`. The answer.
    private func agent(_ path: String = "/v1/messages", headers extra: [(String, String)] = []) throws
        -> (status: Int, headers: [String], body: String) {
        let socket = agent_proxy_connect_tcp("127.0.0.1", UInt16(port))
        guard socket >= 0 else { throw XCTSkip("the relay listener can't be reached") }
        let connect = ProxyProtocolHeader.relayed(lease: "lease-9", relayToken: Self.relayToken).encoded()
            + Array("CONNECT api.anthropic.com:443 HTTP/1.1\r\n\r\n".utf8)
        _ = connect.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
        agent_proxy_set_receive_timeout(socket, 10)
        var head: [UInt8] = []
        var byte: UInt8 = 0
        while !head.suffix(4).elementsEqual(Array("\r\n\r\n".utf8)) {
            guard read(socket, &byte, 1) == 1 else {
                close(socket)
                return (0, [], String(decoding: head, as: UTF8.self))
            }
            head.append(byte)
        }
        guard String(decoding: head, as: UTF8.self).hasPrefix("HTTP/1.1 200 ") else {
            close(socket)
            return (0, [], String(decoding: head, as: UTF8.self))
        }
        var trust = TLSConfiguration.makeClientConfiguration()
        trust.trustRoots = .certificates([try NIOSSLCertificate(bytes: Array(try proxyCA.pem.utf8), format: .pem)])
        let context = try NIOSSLContext(configuration: trust)
        let promise = group.next().makePromise(of: (status: Int, headers: [String], body: [UInt8]).self)
        let channel = try ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(try NIOSSLClientHandler(context: context, serverHostname: AnthropicInterceptor.host))
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                    try channel.pipeline.syncOperations.addHandler(Collector(promise: promise))
                }
            }
            .withConnectedSocket(socket)
            .wait()
        let body = Array(#"{"model":"claude-opus","max_tokens":1,"messages":[]}"#.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "host", value: AnthropicInterceptor.host)
        headers.add(name: "authorization", value: "Bearer visor-agent-proxy")
        headers.add(name: "content-type", value: "application/json")
        headers.add(name: "content-length", value: "\(body.count)")
        for (name, value) in extra { headers.add(name: name, value: value) }
        channel.write(HTTPClientRequestPart.head(HTTPRequestHead(version: .http1_1, method: .POST, uri: path, headers: headers)), promise: nil)
        var buffer = channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
        channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(15)) { promise.fail(ChannelError.connectTimeout(.seconds(15))) }
        defer { timeout.cancel() }
        let got = try promise.futureResult.wait()
        try? channel.close().wait()
        return (got.status, got.headers, String(decoding: got.body, as: UTF8.self))
    }

    func testARequestGoesOnWithTheCredentialWhichNeverComesBack() throws {
        let answer = try agent(headers: [("x-api-key", "sk-ant-api03-agents-own"), ("anthropic-beta", "claude-code-20250219, interleaved-thinking")])
        XCTAssertEqual(answer.status, 200, answer.body)
        let heard = try XCTUnwrap(anthropic.requests.first)
        XCTAssertEqual(heard["authorization"], "Bearer " + Self.credential, "the placeholder replaced")
        XCTAssertNil(heard["x-api-key"], "the agent's own key taken off")
        XCTAssertEqual(heard["anthropic-beta"], "claude-code-20250219,interleaved-thinking,oauth-2025-04-20", "the OAuth beta merged in")
        XCTAssertEqual(heard["host"], "api.anthropic.com")
        XCTAssertEqual(heard["body"], "52", "the body streamed on whole")
        XCTAssertFalse(answer.body.contains(Self.credential), "masked in the body: \(answer.body)")
        XCTAssertTrue(answer.body.contains(String(repeating: "*", count: Self.credential.count)), answer.body)
        XCTAssertFalse(answer.headers.contains { $0.contains(Self.credential) }, "masked in the headers: \(answer.headers)")
        XCTAssertFalse(lines.all.contains { $0.contains(Self.credential) }, "never logged")
        let logged = try String(contentsOf: egress.file, encoding: .utf8)
        XCTAssertFalse(logged.contains(Self.credential) || logged.contains("sk-ant"), logged)
        let entries = egress.entries()
        XCTAssertTrue(entries.contains { $0.route == .anthropic && $0.method == "POST" && $0.pathClass == "/v1/messages" && $0.outcome == .forwarded },
                      "\(entries)")
    }

    /// The beta given already is sent once.
    func testTheOAuthBetaIsntSentTwice() throws {
        _ = try agent(headers: [("anthropic-beta", "oauth-2025-04-20"), ("anthropic-beta", "files-api-2025-04-14,oauth-2025-04-20")])
        XCTAssertEqual(anthropic.requests.first?["anthropic-beta"], "oauth-2025-04-20,files-api-2025-04-14")
    }

    /// No credential kept: 401 in Anthropic's form, saying where to sign
    /// in, and nothing reaches Anthropic; kept again, the next goes on.
    func testWithNoCredentialItsRefusedSayingWhereToSignIn() throws {
        kept.withLock { $0 = nil }
        let refused = try agent()
        XCTAssertEqual(refused.status, 401, refused.body)
        XCTAssertTrue(refused.body.contains("authentication_error"), refused.body)
        XCTAssertTrue(refused.body.contains("Sign In to Claude in Visor's Settings › Sessions Container"), refused.body)
        XCTAssertEqual(anthropic.requests.count, 0, "nothing reached Anthropic")
        XCTAssertTrue(egress.entries().contains { $0.route == .anthropic && $0.outcome == .refused })
        kept.withLock { $0 = "  \n" }
        XCTAssertEqual(try agent().status, 401, "a blank one is none")
        kept.withLock { $0 = Self.credential }
        XCTAssertEqual(try agent().status, 200)
        XCTAssertEqual(anthropic.requests.count, 1)
    }

    /// The headers as they go on, alone: every credential of the agent's
    /// taken off, the kept one on, and the betas merged.
    func testTheOutgoingHeaders() {
        var given = HTTPHeaders()
        given.add(name: "Authorization", value: "Bearer visor-agent-proxy")
        given.add(name: "X-Api-Key", value: "sk-ant-api03-x")
        given.add(name: "Proxy-Authorization", value: "Basic x")
        given.add(name: "anthropic-version", value: "2023-06-01")
        let out = AnthropicInterceptor.outgoing(given, token: "sk-ant-oat01-t")
        XCTAssertEqual(out["authorization"], ["Bearer sk-ant-oat01-t"])
        XCTAssertEqual(out["x-api-key"], [])
        XCTAssertEqual(out["proxy-authorization"], [])
        XCTAssertEqual(out["anthropic-beta"], ["oauth-2025-04-20"])
        XCTAssertEqual(out["anthropic-version"], ["2023-06-01"], "the rest as it was")
        XCTAssertEqual(out["accept-encoding"], ["identity"], "its answer plain, to be masked")
    }

    /// api.anthropic.com on 443 alone; and the authority's leaves for it
    /// alone, its constraint Anthropic's API's.
    func testOnlyAnthropicsAPIIsOpened() throws {
        XCTAssertTrue(interceptor.intercepts(.init(host: "API.anthropic.com", port: 443)))
        XCTAssertFalse(interceptor.intercepts(.init(host: "api.anthropic.com", port: 80)))
        XCTAssertFalse(interceptor.intercepts(.init(host: "console.anthropic.com", port: 443)))
        XCTAssertFalse(interceptor.intercepts(.init(host: "api.github.com", port: 443)))
        XCTAssertEqual(try proxyCA.certificate.extensions.nameConstraints?.permittedDNSDomains, ["api.anthropic.com"])
        XCTAssertThrowsError(try proxyCA.leaf(for: "github.com")) { error in
            XCTAssertEqual(error as? AgentProxyCAError, .notItsHost("github.com"))
        }
    }

    /// The host's way to it: Anthropic's authority made in its secrets
    /// beside GitHub's, its certificate written; made with no credential
    /// too, each request then refused.
    func testTheHostMakesItFromItsSecrets() throws {
        let secrets = MemoryProxySecrets()
        let path = folder.appendingPathComponent("agent-proxy/anthropic-ca.pem").path
        let lines = Lines()
        let made = AnthropicInterceptor.make(secrets: secrets, caCertificate: path, token: { nil }, egress: nil, log: { lines.add($0) })
        XCTAssertNotNil(made)
        made?.stop()
        XCTAssertTrue(lines.all.contains { $0.contains("no Claude credential yet") }, "\(lines.all)")
        XCTAssertEqual(secrets.accounts, ["agent-proxy/anthropic-ca-key.pem", "agent-proxy/anthropic-ca.pem"])
        let ca = try AgentProxyCA.kept(in: secrets, scope: .anthropic)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), try ca.pem)
        XCTAssertFalse(try String(contentsOfFile: path, encoding: .utf8).contains("PRIVATE KEY"))
    }
}
