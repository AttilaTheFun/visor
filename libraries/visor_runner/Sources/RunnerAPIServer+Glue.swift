import NIOCore

// Two connections joined byte for byte (a WebSocket through the Runner,
// once its upgrade has gone on): what one reads, the other writes, and one
// closing closes the other. Both are on one event loop (the server's
// connection is made on the client's), so each calls its partner directly.

extension RunnerAPIServer {
    final class Glue: ChannelDuplexHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private var partner: Glue?
        private var context: ChannelHandlerContext?
        /// What came for this side before it was added to its pipeline.
        private var pending: [ByteBuffer] = []

        /// A joined pair: the first for one channel, the second for the other.
        static func pair() -> (Glue, Glue) {
            let first = Glue()
            let second = Glue()
            first.partner = second
            second.partner = first
            return (first, second)
        }

        func handlerAdded(context: ChannelHandlerContext) {
            self.context = context
            for buffer in pending { context.write(wrapOutboundOut(buffer), promise: nil) }
            if !pending.isEmpty { context.flush() }
            pending = []
        }

        func handlerRemoved(context: ChannelHandlerContext) {
            self.context = nil
            partner = nil
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            partner?.send(unwrapInboundIn(data))
        }

        func channelReadComplete(context: ChannelHandlerContext) {
            partner?.context?.flush()
        }

        func channelInactive(context: ChannelHandlerContext) {
            partner?.context?.close(promise: nil)
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            context.close(promise: nil)
        }

        private func send(_ buffer: ByteBuffer) {
            guard let context else {
                pending.append(buffer)
                return
            }
            context.write(wrapOutboundOut(buffer), promise: nil)
        }
    }
}
