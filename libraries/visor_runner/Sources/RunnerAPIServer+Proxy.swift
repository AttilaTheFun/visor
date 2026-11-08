import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

// A server's whole API through the Runner (docs/runner-accounts.md, step 4):
// `/runner/v1/servers/<id>/<path>` is passed on to the server the Runner
// reaches as `<id>` (runner.json's `reaches`) as `/<path>`, once the
// client's session is checked, with the server's own password in place of
// the client's bearer. Each request goes on a connection of its own; the
// answer comes back as it comes. A WebSocket through the Runner is the
// next part: until then a client's channel is refused and it polls.

extension RunnerAPIServer {
    /// Where a server is, and its password.
    public struct Reach: Sendable {
        public var host: String
        public var port: Int
        public var password: String

        public init(host: String, port: Int, password: String) {
            self.host = host
            self.port = port
            self.password = password
        }
    }

    /// Where the secrets keep a server's password for the Runner.
    public static func passwordSecret(_ server: String) -> String { "server password \(server)" }

    /// A request for a server: its id and the path it goes to there. Nil for
    /// the Runner's own requests.
    static func proxied(_ uri: String) -> (server: String, path: String)? {
        let prefix = "/runner/v1/servers/"
        guard uri.hasPrefix(prefix) else { return nil }
        let rest = uri.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let server = String(rest[..<slash])
        guard !server.isEmpty, !server.contains("?") else { return nil }
        return (server, String(rest[slash...]))
    }

    /// The headers a request goes on with: its own, but those of the hop
    /// and the client's bearer; the server's password, the server as Host.
    static func forwardedHeaders(_ given: HTTPHeaders, reach: Reach, length: Int) -> HTTPHeaders {
        let hop: Set<String> = ["connection", "keep-alive", "proxy-authorization", "proxy-connection", "te", "trailer",
                                "transfer-encoding", "upgrade", "host", "authorization", "content-length"]
        var headers = HTTPHeaders(given.filter { !hop.contains($0.name.lowercased()) }.map { ($0.name, $0.value) })
        headers.add(name: "Host", value: "\(reach.host):\(reach.port)")
        headers.add(name: "Authorization", value: "Bearer \(reach.password)")
        headers.add(name: "Content-Length", value: String(length))
        headers.add(name: "Connection", value: "close")
        return headers
    }

    /// The server's answer, back to the client as it comes.
    final class UpstreamHandler: ChannelInboundHandler {
        typealias InboundIn = HTTPClientResponsePart

        let client: NIOLoopBound<ChannelHandlerContext>
        let handler: NIOLoopBound<Handler>
        private var answered = false

        init(client: NIOLoopBound<ChannelHandlerContext>, handler: NIOLoopBound<Handler>) {
            self.client = client
            self.handler = handler
        }

        // The server's connection is on the client's own event loop
        // (ClientBootstrap(group: context.eventLoop)), so its parts go
        // straight on.
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let given):
                answered = true
                var head = given
                // The client's connection is the Runner's to keep or close.
                for name in ["connection", "keep-alive", "transfer-encoding"] { head.headers.remove(name: name) }
                if !head.headers.contains(name: "content-length") { head.headers.add(name: "Transfer-Encoding", value: "chunked") }
                handler.value.relay(client.value, .head(head))
            case .body(let buffer):
                handler.value.relay(client.value, .body(.byteBuffer(buffer)))
            case .end(let trailers):
                handler.value.relay(client.value, .end(trailers))
                context.close(promise: nil)
            }
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            if answered {
                client.value.close(promise: nil)
            } else {
                handler.value.respond(client.value, RunnerAPI.json(502, ["error": "The server didn't answer"]))
            }
            context.close(promise: nil)
        }
    }
}

extension RunnerAPIServer.Handler {
    /// A request for a server, on its way: its session checked, the server
    /// found, then sent on.
    func proxy(_ context: ChannelHandlerContext, server: String, path: String, head: HTTPRequestHead, body: ByteBuffer?) {
        guard api.user(for: head.headers["authorization"].first) != nil else {
            respond(context, RunnerAPI.refused)
            return
        }
        guard let reach = reach(server) else {
            respond(context, RunnerAPI.json(404, ["error": "No such server here"]))
            return
        }
        if head.headers["upgrade"].contains(where: { $0.lowercased() == "websocket" }) {
            respond(context, RunnerAPI.json(501, ["error": "A WebSocket through the Runner comes later: poll"]))
            return
        }
        let length = body?.readableBytes ?? 0
        let sent = HTTPRequestHead(version: .http1_1, method: head.method, uri: path,
                                   headers: RunnerAPIServer.forwardedHeaders(head.headers, reach: reach, length: length))
        let client = NIOLoopBound(context, eventLoop: context.eventLoop)
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        ClientBootstrap(group: context.eventLoop)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let operations = channel.pipeline.syncOperations
                    try operations.addHTTPClientHandlers()
                    try operations.addHandler(RunnerAPIServer.UpstreamHandler(client: client, handler: handler))
                }
            }
            .connect(host: reach.host, port: reach.port)
            .whenComplete { result in
                switch result {
                case .failure:
                    handler.value.respond(client.value, RunnerAPI.json(502, ["error": "The server can't be reached"]))
                case .success(let channel):
                    channel.write(HTTPClientRequestPart.head(sent), promise: nil)
                    if let body { channel.write(HTTPClientRequestPart.body(.byteBuffer(body)), promise: nil) }
                    channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
                }
            }
    }

    /// A part of a server's answer, to the client.
    func relay(_ context: ChannelHandlerContext, _ part: HTTPServerResponsePart) {
        if case .end = part {
            context.writeAndFlush(wrapOutboundOut(part), promise: nil)
            clearRequest()
        } else {
            context.write(wrapOutboundOut(part), promise: nil)
            if case .body = part { context.flush() }
        }
    }
}
