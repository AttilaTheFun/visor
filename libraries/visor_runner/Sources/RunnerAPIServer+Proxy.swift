import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

// A server's whole API through the Runner (docs/runner-accounts.md, step 4):
// `/runner/v1/servers/<id>/<path>` is passed on to the server the Runner
// reaches as `<id>` (runner.json's `reaches`) as `/<path>`, once the
// client's session is checked, with the server's own password in place of
// the client's bearer. Each request goes on a connection of its own; the
// answer comes back as it comes. A WebSocket's upgrade goes on as it came
// (its key and its version), and once it has, the two connections are
// joined byte for byte: the server's own 101, then every frame, each way.

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
            tunnel(context, path: path, head: head, reach: reach)
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

    /// A WebSocket's upgrade, on to the server as it came (but its bearer
    /// and Host), on a connection of its own; then the client's HTTP
    /// handlers come off and the two connections are joined.
    func tunnel(_ context: ChannelHandlerContext, path: String, head: HTTPRequestHead, reach: RunnerAPIServer.Reach) {
        let dropped: Set<String> = ["host", "authorization", "proxy-authorization", "proxy-connection", "content-length", "transfer-encoding"]
        var lines = ["GET \(path) HTTP/1.1", "Host: \(reach.host):\(reach.port)", "Authorization: Bearer \(reach.password)"]
        lines += head.headers.filter { !dropped.contains($0.name.lowercased()) }.map { "\($0.name): \($0.value)" }
        let request = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        let (clientSide, serverSide) = RunnerAPIServer.Glue.pair()
        let ends = NIOLoopBound((client: clientSide, server: serverSide), eventLoop: context.eventLoop)
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        ClientBootstrap(group: context.eventLoop)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(ends.value.server) }
            }
            .connect(host: reach.host, port: reach.port)
            .whenComplete { result in
                let context = bound.value
                switch result {
                case .failure:
                    handler.value.respond(context, RunnerAPI.json(502, ["error": "The server can't be reached"]))
                case .success(let channel):
                    var buffer = channel.allocator.buffer(capacity: request.count)
                    buffer.writeBytes(request)
                    channel.writeAndFlush(buffer, promise: nil)
                    do {
                        let pipeline = context.pipeline.syncOperations
                        // The HTTP handlers off but the decoder, then the glue
                        // on (no encoder before it, so the server's bytes go
                        // out as they are), then the decoder off, handing what
                        // it read past the upgrade on to the glue.
                        // Each removal checked: a handler left behind would
                        // be handed the WebSocket's bytes.
                        let removed = [RunnerAPIServer.Names.handler, RunnerAPIServer.Names.errors, RunnerAPIServer.Names.encoder]
                            .map { pipeline.removeHandler(name: $0) }
                        try pipeline.addHandler(ends.value.client)
                        let decoder = pipeline.removeHandler(name: RunnerAPIServer.Names.decoder)
                        for removal in removed + [decoder] {
                            removal.whenFailure { _ in
                                channel.close(promise: nil)
                                bound.value.close(promise: nil)
                            }
                        }
                    } catch {
                        channel.close(promise: nil)
                        context.close(promise: nil)
                    }
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
