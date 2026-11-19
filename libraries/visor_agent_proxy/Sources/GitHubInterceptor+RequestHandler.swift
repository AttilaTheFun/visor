import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

// One intercepted connection's requests, one at a time (the HTTP server
// pipeline holds the next until a response has ended): each read as far as
// the gate needs (a write's JSON whole, a push's command list), decided and
// checked, then sent on to GitHub with logan-shire-agent's token and the rest
// of its body streamed after it, or refused in its client's form; each a line
// of the egress log. Moved from MultiPass (Logan, 2026-11-14). While a request
// is decided and GitHub's connection made, the client's stream isn't read
// (autoRead off), so what is held meanwhile is what was read already; past
// 8 MiB of it all the same, the request is refused 413 in its client's form
// (NCH's follow-up to #417: it was held without a bound).

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

        /// Where the request in hand is: its body read for the gate, held while
        /// it's decided and while GitHub's connection is made (`connecting`:
        /// what comes then is kept, in order, and sent once it's made), then
        /// streamed on.
        enum Phase {
            case idle, reading, deciding, connecting, forwarding, answered
        }

        static let wholeLimit = 8 << 20
        static let commandsLimit = 1 << 20
        /// The most of a body held while it's decided and connected (NCH's
        /// follow-up to #417): reading is off then, so this is a bound, not a
        /// limit a client meets.
        static let waitingLimit = 8 << 20

        let interceptor: GitHubInterceptor
        let host: String
        let caller: EgressProxy.Caller
        private var head: HTTPRequestHead?
        private var reading = Reading.nothing
        private var phase = Phase.idle
        private var body: ByteBuffer?
        private var waiting: [HTTPServerRequestPart] = []
        private var waitingBytes = 0
        private var ended = false
        private var upstream: Channel?
        private var token = ""
        private var repository = ""
        /// What the gate made of the request in hand, for the egress log.
        private var decision: GateDecision?

        init(interceptor: GitHubInterceptor, host: String, caller: EgressProxy.Caller) {
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
                waitingBytes = 0
                ended = false
                decision = nil
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
                        answer(context, refusal: "a body over \(Self.wholeLimit >> 20) MiB isn't read by the agent proxy")
                    }
                case .deciding, .connecting:
                    waitingBytes += buffer.readableBytes
                    guard waitingBytes <= Self.waitingLimit else {
                        waiting = []
                        answer(context, refusal: "more than \(Self.waitingLimit >> 20) MiB of a body came before it was decided", tooLarge: true)
                        return
                    }
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
                case .deciding, .connecting: waiting.append(part)
                case .forwarding: upstream?.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
                case .idle, .answered: break
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

        /// The client's stream read, or left unread (while a request is
        /// decided and connected: what comes meanwhile waits in the socket).
        private func setReading(_ context: ChannelHandlerContext, _ on: Bool) {
            _ = context.channel.setOption(ChannelOptions.autoRead, value: on)
        }

        private func decide(_ context: ChannelHandlerContext) {
            guard let head else { return }
            phase = .deciding
            setReading(context, false)
            let request = GateRequest(method: head.method.rawValue, host: host, target: head.uri,
                                      body: body.map { Data($0.readableBytesView) })
            let decision = head.headers["content-encoding"].contains(where: { !$0.isEmpty && $0 != "identity" }) && reading != .nothing
                ? GateDecision.refuse("a compressed body isn't read by the agent proxy") : interceptor.gate.decide(request)
            self.decision = decision
            let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            let interceptor = self.interceptor
            let caller = self.caller
            context.eventLoop.makeFutureWithTask { await interceptor.settle(decision, caller: caller) }
                .whenComplete { result in
                    let context = bound.value
                    // Answered meanwhile (too much came, or the client went): nothing more to do.
                    guard handler.value.phase == .deciding else { return }
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
        func answer(_ context: ChannelHandlerContext, refusal reason: String, failed: Bool = false, tooLarge: Bool = false) {
            guard let head else { return }
            phase = .answered
            interceptor.log("\(caller.session) \(head.method.rawValue) \(host)\(Self.template(head.uri)) \(failed ? "failed" : "refused"): \(reason)")
            interceptor.record(caller, host: host, method: head.method.rawValue, uri: head.uri, decision: decision, failed ? .unreachable : .refused)
            let (response, bytes) = GitHubInterceptor.refusal(reason, failed: failed, tooLarge: tooLarge, method: head.method, host: host,
                                                              uri: head.uri, body: body.map { Array($0.readableBytesView) })
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
            setReading(context, true)
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
            for name in ["authorization", "proxy-authorization", "proxy-connection"] + Self.methodOverrides { head.headers.remove(name: name) }
            head.headers.replaceOrAdd(name: "host", value: host)
            // GitHub's answer as plain bytes, so a token in it can be found and masked (NCH's review of #417).
            head.headers.replaceOrAdd(name: "accept-encoding", value: "identity")
            // An anonymous read (no token) goes on with no authorization at
            // all, the client's placeholder taken off as always.
            if !token.isEmpty {
                head.headers.add(name: "authorization", value: host == "github.com"
                    ? "Basic " + Data("x-access-token:\(token)".utf8).base64EncodedString() : "Bearer " + token)
            }
            interceptor.log("\(caller.session) \(head.method.rawValue) \(host)\(Self.template(head.uri)) \(repository) "
                + (token.isEmpty ? "forwarded anonymously" : "forwarded"))
            // Until GitHub's connection is made, what more comes of the body is kept (NCH's review of #417: it was
            // sent to no connection and lost), then sent after the head and what was read, in order.
            phase = .connecting
            let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            let sent = head
            let first = held
            connect(context).whenComplete { result in
                let context = bound.value
                let handled = handler.value
                // The client gone meanwhile: nothing to send, and GitHub's connection let go.
                guard handled.phase == .connecting else {
                    if case .success(let channel) = result { channel.close(promise: nil) }
                    return
                }
                switch result {
                case .failure(let error):
                    handled.waiting = []
                    handled.answer(context, refusal: "GitHub can't be reached: \(error)", failed: true)
                case .success(let channel):
                    handled.interceptor.record(handled.caller, host: handled.host, method: sent.method.rawValue, uri: sent.uri,
                                               decision: handled.decision, .forwarded)
                    channel.write(HTTPClientRequestPart.head(sent), promise: nil)
                    if let first { channel.write(HTTPClientRequestPart.body(.byteBuffer(first)), promise: nil) }
                    for part in handled.waiting {
                        switch part {
                        case .body(let buffer): channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
                        case .end: channel.write(HTTPClientRequestPart.end(nil), promise: nil)
                        case .head: break
                        }
                    }
                    handled.waiting = []
                    handled.waitingBytes = 0
                    handled.phase = .forwarding
                    channel.flush()
                    // The rest of the body as it comes, now there's somewhere to send it.
                    handled.setReading(context, true)
                }
            }
        }

        /// The connection to GitHub, made once for this client's requests.
        private func connect(_ context: ChannelHandlerContext) -> EventLoopFuture<Channel> {
            if let upstream, upstream.isActive { return context.eventLoop.makeSucceededFuture(upstream) }
            let address = interceptor.upstream.address(host)
            let delay = interceptor.upstream.delay
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
                .flatMap { channel in
                    // A test's way to hold the connection back, as a far GitHub's would be.
                    guard delay > .zero else { return channel.eventLoop.makeSucceededFuture(channel) }
                    return channel.eventLoop.scheduleTask(in: delay) { channel }.futureResult
                }
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

        /// Headers that would have GitHub take a request as another method than
        /// the one the gate decided: never sent on (NCH's review of #417).
        static let methodOverrides = ["x-http-method-override", "x-http-method", "x-method-override"]

        /// A path as the log keeps it: without its query.
        static func template(_ uri: String) -> String {
            uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        }

        var heldToken: String { token }
    }

    /// GitHub's answer, back to the client, the token masked in it: in its
    /// headers, and in its body however the body is split (the last bytes of
    /// each piece held back until the next shows they're no token's start).
    final class UpstreamHandler: ChannelInboundHandler {
        typealias InboundIn = HTTPClientResponsePart

        let client: Channel
        let request: NIOLoopBound<RequestHandler>
        private var status = HTTPResponseStatus.ok
        private var scrubber = Scrubber(token: "")

        init(client: Channel, request: NIOLoopBound<RequestHandler>) {
            self.client = client
            self.request = request
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(var head):
                status = head.status
                scrubber = Scrubber(token: request.value.heldToken)
                head.headers = GitHubInterceptor.scrubbed(head.headers, request.value.heldToken)
                client.write(HTTPServerResponsePart.head(head), promise: nil)
            case .body(let buffer):
                let passed = scrubber.pass(Array(buffer.readableBytesView))
                guard !passed.isEmpty else { return }
                client.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: passed))), promise: nil)
            case .end(let trailers):
                let rest = scrubber.finish()
                if !rest.isEmpty { client.write(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: rest))), promise: nil) }
                client.writeAndFlush(HTTPServerResponsePart.end(trailers.map { GitHubInterceptor.scrubbed($0, request.value.heldToken) }),
                                     promise: nil)
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
