import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

// One intercepted connection's requests to api.anthropic.com, one at a time
// (the HTTP server pipeline holds the next until a response has ended): each
// head given the credential (AnthropicInterceptor.outgoing) and sent on, its
// body streamed after it; or, with no credential kept, answered 401 there
// and then. While Anthropic's connection is made the client's stream isn't
// read (autoRead off), and what came already is kept, in order, and sent
// once it's made. The answer comes back as it streams (a message's events),
// the credential masked should it appear.

extension AnthropicInterceptor {
    final class RequestHandler: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        /// Where the request in hand is: its head sent once Anthropic's
        /// connection is made (`connecting`: what comes meanwhile is kept),
        /// then streamed on; or answered here.
        enum Phase {
            case idle, connecting, forwarding, answered
        }

        let interceptor: AnthropicInterceptor
        let caller: EgressProxy.Caller
        private var phase = Phase.idle
        private var waiting: [HTTPServerRequestPart] = []
        private var ended = false
        private var upstream: Channel?
        private var token = ""

        init(interceptor: AnthropicInterceptor, caller: EgressProxy.Caller) {
            self.interceptor = interceptor
            self.caller = caller
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let part = unwrapInboundIn(data)
            switch part {
            case .head(let head):
                waiting = []
                ended = false
                guard let token = interceptor.credential else { return refuse(context, head) }
                forward(context, head, token: token)
            case .body(let buffer):
                switch phase {
                case .connecting: waiting.append(part)
                case .forwarding: upstream?.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
                case .idle, .answered: break
                }
            case .end:
                ended = true
                switch phase {
                case .connecting: waiting.append(part)
                case .forwarding: upstream?.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
                case .answered:
                    // The refusal went before the body ended: now the next may come.
                    phase = .idle
                case .idle: break
                }
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            phase = .answered
            waiting = []
            upstream?.close(promise: nil)
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            upstream?.close(promise: nil)
            context.close(promise: nil)
        }

        /// No credential: 401, and the rest of the request read and left.
        private func refuse(_ context: ChannelHandlerContext, _ head: HTTPRequestHead) {
            phase = .answered
            interceptor.log("\(caller.session) \(head.method.rawValue) \(AnthropicInterceptor.host)\(Self.template(head.uri)) refused: no Claude credential")
            interceptor.record(caller, method: head.method.rawValue, uri: head.uri, .refused)
            write(context, AnthropicInterceptor.refusal())
        }

        /// An answer of the proxy's own, whole.
        private func write(_ context: ChannelHandlerContext, _ answer: (HTTPResponseHead, [UInt8])) {
            var buffer = context.channel.allocator.buffer(capacity: answer.1.count)
            buffer.writeBytes(answer.1)
            context.write(wrapOutboundOut(.head(answer.0)), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }

        /// The request sent on: its head with the credential, then its body as
        /// it comes.
        private func forward(_ context: ChannelHandlerContext, _ given: HTTPRequestHead, token: String) {
            self.token = token
            var head = given
            head.headers = AnthropicInterceptor.outgoing(given.headers, token: token)
            interceptor.log("\(caller.session) \(head.method.rawValue) \(AnthropicInterceptor.host)\(Self.template(head.uri)) forwarded")
            phase = .connecting
            _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
            let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            let sent = head
            connect(context).whenComplete { result in
                let context = bound.value
                let handled = handler.value
                // The client gone meanwhile: Anthropic's connection let go.
                guard handled.phase == .connecting else {
                    if case .success(let channel) = result { channel.close(promise: nil) }
                    return
                }
                switch result {
                case .failure(let error):
                    handled.waiting = []
                    handled.phase = .answered
                    handled.interceptor.log("\(handled.caller.session) \(AnthropicInterceptor.host) can't be reached: \(error)")
                    handled.interceptor.record(handled.caller, method: sent.method.rawValue, uri: sent.uri, .unreachable)
                    handled.write(context, Self.unreachable())
                    if handled.ended { handled.phase = .idle } else { context.close(promise: nil) }
                case .success(let channel):
                    handled.interceptor.record(handled.caller, method: sent.method.rawValue, uri: sent.uri, .forwarded)
                    channel.write(HTTPClientRequestPart.head(sent), promise: nil)
                    for part in handled.waiting {
                        switch part {
                        case .body(let buffer): channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
                        case .end: channel.write(HTTPClientRequestPart.end(nil), promise: nil)
                        case .head: break
                        }
                    }
                    handled.waiting = []
                    handled.phase = .forwarding
                    channel.flush()
                    // The rest of the body as it comes, now there's somewhere to send it.
                    _ = context.channel.setOption(ChannelOptions.autoRead, value: true)
                }
            }
        }

        /// Anthropic not reached: 502, in its error form.
        static func unreachable() -> (HTTPResponseHead, [UInt8]) {
            let object: [String: Any] = ["type": "error", "error": ["type": "api_error", "message": "Visor's agent-proxy couldn't reach api.anthropic.com."]]
            let bytes = Array((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data())
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "application/json")
            headers.add(name: "content-length", value: "\(bytes.count)")
            return (HTTPResponseHead(version: .http1_1, status: .badGateway, headers: headers), bytes)
        }

        /// The connection to Anthropic, made once for this client's requests.
        private func connect(_ context: ChannelHandlerContext) -> EventLoopFuture<Channel> {
            if let upstream, upstream.isActive { return context.eventLoop.makeSucceededFuture(upstream) }
            let address = interceptor.upstream.address(AnthropicInterceptor.host)
            let tls = interceptor.upstreamContext
            let client = context.channel
            let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
            return ClientBootstrap(group: context.eventLoop)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let operations = channel.pipeline.syncOperations
                        try operations.addHandler(try NIOSSLClientHandler(context: tls, serverHostname: AnthropicInterceptor.host))
                        try operations.addHTTPClientHandlers()
                        try operations.addHandler(UpstreamHandler(client: client, request: handler))
                    }
                }
                .connect(host: address.host, port: address.port)
                .map { channel in
                    handler.value.upstream = channel
                    return channel
                }
        }

        /// The response has ended: the next request may come.
        func responded() { phase = .idle }

        /// A path as the log keeps it: without its query.
        static func template(_ uri: String) -> String {
            uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        }

        var heldToken: String { token }
    }

    /// Anthropic's answer, back to the client as it streams, the credential
    /// masked in it: in its headers, and in its body however the body is
    /// split.
    final class UpstreamHandler: ChannelInboundHandler {
        typealias InboundIn = HTTPClientResponsePart

        let client: Channel
        let request: NIOLoopBound<RequestHandler>
        private var scrubber = GitHubInterceptor.Scrubber(token: "")

        init(client: Channel, request: NIOLoopBound<RequestHandler>) {
            self.client = client
            self.request = request
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let token = request.value.heldToken
            switch unwrapInboundIn(data) {
            case .head(var head):
                scrubber = GitHubInterceptor.Scrubber(token: token)
                head.headers = GitHubInterceptor.scrubbed(head.headers, token)
                client.writeAndFlush(HTTPServerResponsePart.head(head), promise: nil)
            case .body(let buffer):
                let passed = scrubber.pass(Array(buffer.readableBytesView))
                guard !passed.isEmpty else { return }
                client.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: passed))), promise: nil)
            case .end(let trailers):
                let rest = scrubber.finish()
                if !rest.isEmpty { client.write(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: rest))), promise: nil) }
                client.writeAndFlush(HTTPServerResponsePart.end(trailers.map { GitHubInterceptor.scrubbed($0, token) }), promise: nil)
                request.value.responded()
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            client.close(promise: nil)
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            context.close(promise: nil)
        }
    }
}
