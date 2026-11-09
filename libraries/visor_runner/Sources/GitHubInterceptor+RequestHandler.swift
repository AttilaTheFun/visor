import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

// One intercepted connection's requests, one at a time (the HTTP server
// pipeline holds the next until a response has ended): each read as far as
// the gate needs (a write's JSON whole, a push's command list), decided and
// checked, then sent on to GitHub with the session's token and the rest of
// its body streamed after it, or refused in its client's form.

extension GitHubInterceptor {
    final class RequestHandler: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        /// What of a request's body the gate reads before it decides.
        enum Reading {
            case nothing
            /// The whole body, up to its limit: a JSON write, GraphQL, LFS.
            case whole
            /// A push's command list, up to its flush.
            case pushCommands
        }

        enum Phase {
            case idle, reading, deciding, forwarding, answered
        }

        static let wholeLimit = 8 << 20
        static let commandsLimit = 1 << 20

        let interceptor: GitHubInterceptor
        let host: String
        let caller: GitHubProxy.Caller
        private var head: HTTPRequestHead?
        private var reading = Reading.nothing
        private var phase = Phase.idle
        private var body: ByteBuffer?
        private var waiting: [HTTPServerRequestPart] = []
        private var ended = false
        private var upstream: Channel?
        private var token = ""
        private var repository = ""

        init(interceptor: GitHubInterceptor, host: String, caller: GitHubProxy.Caller) {
            self.interceptor = interceptor
            self.host = host
            self.caller = caller
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let part = unwrapInboundIn(data)
            switch part {
            case .head(let given):
                head = given
                body = nil
                waiting = []
                ended = false
                reading = Self.reading(given, host: host)
                phase = .reading
                if case .nothing = reading { decide(context) }
            case .body(let buffer):
                switch phase {
                case .reading:
                    var held = body ?? context.channel.allocator.buffer(capacity: buffer.readableBytes)
                    var given = buffer
                    held.writeBuffer(&given)
                    body = held
                    if case .pushCommands = reading {
                        switch GitPushCommands.read(Array(held.readableBytesView)) {
                        case .list: decide(context)
                        case .invalid: answer(context, refusal: "a push's commands can't be read")
                        case .incomplete: if held.readableBytes > Self.commandsLimit { answer(context, refusal: "a push's commands are too long") }
                        }
                    } else if held.readableBytes > Self.wholeLimit {
                        answer(context, refusal: "a body over \(Self.wholeLimit >> 20) MiB isn't read by Visor's proxy")
                    }
                case .deciding:
                    waiting.append(part)
                case .forwarding:
                    upstream?.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
                case .idle, .answered:
                    break
                }
            case .end:
                ended = true
                switch phase {
                case .reading: decide(context)
                case .deciding: waiting.append(part)
                case .forwarding: upstream?.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
                case .idle, .answered: break
                }
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            upstream?.close(promise: nil)
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            upstream?.close(promise: nil)
            context.close(promise: nil)
        }

        /// What the gate reads of a request's body before deciding.
        static func reading(_ head: HTTPRequestHead, host: String) -> Reading {
            let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
            if host == "github.com" {
                if head.method == .POST, path.hasSuffix("/git-receive-pack") { return .pushCommands }
                if head.method == .POST, path.hasSuffix("/info/lfs/objects/batch") { return .whole }
                return .nothing
            }
            return [.POST, .PATCH, .PUT].contains(head.method) ? .whole : .nothing
        }

        private func decide(_ context: ChannelHandlerContext) {
            guard let head else { return }
            phase = .deciding
            let request = GateRequest(method: head.method.rawValue, host: host, target: head.uri,
                                      body: body.map { Data($0.readableBytesView) })
            let decision = head.headers["content-encoding"].contains(where: { !$0.isEmpty && $0 != "identity" }) && reading != .nothing
                ? GateDecision.refuse("a compressed body isn't read by Visor's proxy") : interceptor.gate.decide(request)
            let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            let interceptor = self.interceptor
            let caller = self.caller
            context.eventLoop.makeFutureWithTask { await interceptor.settle(decision, caller: caller) }
                .whenComplete { result in
                    let context = bound.value
                    switch result {
                    case .success(.forward(let repository, let token, let rewrite)):
                        handler.value.forward(context, repository: repository, token: token, rewrite: rewrite)
                    case .success(.refuse(let reason)):
                        handler.value.answer(context, refusal: reason)
                    case .success(.fail(let reason)):
                        handler.value.answer(context, refusal: reason, failed: true)
                    case .failure(let error):
                        handler.value.answer(context, refusal: "\(error)", failed: true)
                    }
                }
        }

        /// A refusal (or a failure) in the client's form, and the rest of the
        /// request read and left.
        func answer(_ context: ChannelHandlerContext, refusal reason: String, failed: Bool = false) {
            guard let head else { return }
            phase = .answered
            interceptor.log("\(caller.session) \(head.method.rawValue) \(host)\(Self.template(head.uri)) \(failed ? "failed" : "refused"): \(reason)")
            let (response, bytes) = GitHubInterceptor.refusal(reason, failed: failed, method: head.method, host: host, uri: head.uri,
                                                              body: body.map { Array($0.readableBytesView) })
            var buffer = context.channel.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            context.write(wrapOutboundOut(.head(response)), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            let closing = !ended
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                // A refusal before the body ended: no more of it is read.
                if closing { bound.value.close(promise: nil) }
            }
            phase = .idle
        }

        /// The request sent on: its head with the token, what was read of its
        /// body (set as a check said), then the rest as it comes.
        private func forward(_ context: ChannelHandlerContext, repository: String, token: String, rewrite: CheckOutcome.Rewrite?) {
            guard var head else { return }
            self.token = token
            self.repository = repository
            var held = body
            if let rewrite, let given = body, let rewritten = GitHubInterceptor.rewritten(Data(given.readableBytesView), rewrite) {
                var buffer = context.channel.allocator.buffer(capacity: rewritten.count)
                buffer.writeBytes(rewritten)
                held = buffer
                head.headers.remove(name: "transfer-encoding")
                head.headers.replaceOrAdd(name: "content-length", value: "\(rewritten.count)")
            }
            for name in ["authorization", "proxy-authorization", "proxy-connection"] { head.headers.remove(name: name) }
            head.headers.replaceOrAdd(name: "host", value: host)
            // An anonymous read (no token) goes on with no authorization at
            // all, the client's placeholder taken off as always.
            if !token.isEmpty {
                head.headers.add(name: "authorization", value: host == "github.com"
                    ? "Basic " + Data("x-access-token:\(token)".utf8).base64EncodedString() : "Bearer " + token)
            }
            interceptor.log("\(caller.session) \(head.method.rawValue) \(host)\(Self.template(head.uri)) \(repository) "
                + (token.isEmpty ? "forwarded anonymously" : "forwarded"))
            phase = .forwarding
            let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            let sent = head
            let first = held
            connect(context).whenComplete { result in
                let context = bound.value
                switch result {
                case .failure(let error):
                    handler.value.answer(context, refusal: "GitHub can't be reached: \(error)", failed: true)
                case .success(let channel):
                    channel.write(HTTPClientRequestPart.head(sent), promise: nil)
                    if let first { channel.write(HTTPClientRequestPart.body(.byteBuffer(first)), promise: nil) }
                    for part in handler.value.waiting {
                        switch part {
                        case .body(let buffer): channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
                        case .end: channel.write(HTTPClientRequestPart.end(nil), promise: nil)
                        case .head: break
                        }
                    }
                    handler.value.waiting = []
                    channel.flush()
                }
            }
        }

        /// The connection to GitHub, made once for this client's requests.
        private func connect(_ context: ChannelHandlerContext) -> EventLoopFuture<Channel> {
            if let upstream, upstream.isActive { return context.eventLoop.makeSucceededFuture(upstream) }
            let address = interceptor.upstream.address(host)
            let tls = interceptor.upstreamContext
            let host = self.host
            let client = context.channel
            let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
            return ClientBootstrap(group: context.eventLoop)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let operations = channel.pipeline.syncOperations
                        try operations.addHandler(try NIOSSLClientHandler(context: tls, serverHostname: host))
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
        func responded(status: HTTPResponseStatus) {
            if status == .unauthorized, !token.isEmpty {
                // GitHub turned the token down: the next request asks again.
                let tokens = interceptor.tokens
                let session = caller.session
                let repository = self.repository
                Task { await tokens.forget(session: session, repository: repository) }
            }
            phase = .idle
        }

        /// A path as the log keeps it: without its query.
        static func template(_ uri: String) -> String {
            uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        }

        var heldToken: String { token }
    }

    /// GitHub's answer, back to the client, the token scrubbed from it.
    final class UpstreamHandler: ChannelInboundHandler {
        typealias InboundIn = HTTPClientResponsePart

        let client: Channel
        let request: NIOLoopBound<RequestHandler>
        private var status = HTTPResponseStatus.ok

        init(client: Channel, request: NIOLoopBound<RequestHandler>) {
            self.client = client
            self.request = request
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                status = head.status
                client.write(HTTPServerResponsePart.head(head), promise: nil)
            case .body(let buffer):
                client.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(GitHubInterceptor.scrubbed(buffer, request.value.heldToken))),
                                     promise: nil)
            case .end(let trailers):
                client.writeAndFlush(HTTPServerResponsePart.end(trailers), promise: nil)
                request.value.responded(status: status)
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
