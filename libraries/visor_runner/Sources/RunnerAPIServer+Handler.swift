import Foundation
import NIOCore
import NIOHTTP1

// One client's requests to the Runner's side for clients, over TLS, one at
// a time (the HTTP server pipeline holds the next until a response ends):
// each read whole (a sign-in's body is small), answered by RunnerAPI off the
// event loop (scrypt takes a while), a refused sign-in after a second.

extension RunnerAPIServer {
    /// Removable: a WebSocket's upgrade takes it off its pipeline.
    final class Handler: ChannelInboundHandler, RemovableChannelHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        /// No request to the Runner's own side has a body larger than this;
        /// one for a server (a file sent to it) up to the second.
        static let bodyLimit = 64 << 10
        static let proxiedLimit = 64 << 20

        let api: RunnerAPI
        let reach: @Sendable (String) -> RunnerAPIServer.Reach?
        private var head: HTTPRequestHead?
        private var body: ByteBuffer?
        private var tooLong = false

        init(api: RunnerAPI, reach: @escaping @Sendable (String) -> RunnerAPIServer.Reach?) {
            self.api = api
            self.reach = reach
        }

        func clearRequest() {
            head = nil
            body = nil
            tooLong = false
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let given):
                head = given
                body = nil
                tooLong = false
            case .body(var buffer):
                var held = body ?? context.channel.allocator.buffer(capacity: buffer.readableBytes)
                held.writeBuffer(&buffer)
                let limit = head.flatMap { RunnerAPIServer.proxied($0.uri) } == nil ? Self.bodyLimit : Self.proxiedLimit
                if held.readableBytes > limit { tooLong = true } else { body = held }
            case .end:
                guard let head else { return }
                if tooLong {
                    respond(context, RunnerAPI.json(413, ["error": "Too long"]))
                    return
                }
                if let target = RunnerAPIServer.proxied(head.uri) {
                    proxy(context, server: target.server, path: target.path, head: head, body: body)
                    return
                }
                let request = (method: head.method.rawValue, path: head.uri, authorization: head.headers["authorization"].first,
                               body: body.map { Data($0.readableBytesView) } ?? Data())
                let api = self.api
                let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
                let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
                let loop = context.eventLoop
                DispatchQueue.global().async {
                    let answer = api.answer(method: request.method, path: request.path, authorization: request.authorization, body: request.body)
                    let wait: TimeAmount = answer.status == 401 && request.method == "POST" ? .seconds(1) : .zero
                    loop.scheduleTask(in: wait) { handler.value.respond(bound.value, answer) }
                }
            }
        }

        func respond(_ context: ChannelHandlerContext, _ answer: RunnerAPI.Answer) {
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")
            headers.add(name: "Content-Length", value: String(answer.body.count))
            headers.add(name: "Cache-Control", value: "no-store")
            let version = head?.version ?? .http1_1
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: answer.status),
                                                                 headers: headers))), promise: nil)
            var buffer = context.channel.allocator.buffer(capacity: answer.body.count)
            buffer.writeBytes(answer.body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            clearRequest()
        }
    }
}
