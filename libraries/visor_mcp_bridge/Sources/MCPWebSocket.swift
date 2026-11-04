import CVisorPOSIX
import Foundation
import Synchronization

/// A WebSocket to Visor's server, from an agent's MCP server: one for each
/// call, as the Node script had. Connected and read on threads of its own,
/// so a call waiting on the server (a person deciding on `approve`) holds
/// no thread of Swift's own pool. Only its reader closes the descriptor,
/// once it has read the end; a write never goes to it after that.
final class MCPWebSocket: Sendable {
    private let descriptor: Int32
    private let alive = Mutex(true)
    /// Each text message the server sends, whole; finished at the end.
    let messages: AsyncStream<String>
    private let arrived: AsyncStream<String>.Continuation

    private init(descriptor: Int32, leftover: [UInt8]) {
        self.descriptor = descriptor
        (messages, arrived) = AsyncStream.makeStream(of: String.self)
        Thread.detachNewThread { [self] in read(leftover) }
    }

    /// A WebSocket to `url` once the server has taken it; nil when it
    /// can't be reached or doesn't answer as one.
    static func open(_ url: String) async -> MCPWebSocket? {
        await withCheckedContinuation { done in
            Thread.detachNewThread { done.resume(returning: connect(url)) }
        }
    }

    private static func connect(_ text: String) -> MCPWebSocket? {
        guard let url = MCPURL(text) else { return nil }
        let descriptor = visor_connect_tcp(url.host, url.port)
        guard descriptor >= 0 else { return nil }
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let request = "GET \(url.path) HTTP/1.1\r\nHost: \(url.hostHeader)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        guard mcpWriteAll(descriptor, Array(request.utf8)) else {
            mcpClose(descriptor)
            return nil
        }
        // The answer's head, then whatever came after it (a first frame).
        var received: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        let end: [UInt8] = Array("\r\n\r\n".utf8)
        while received.count < 64 * 1024 {
            if let found = received.firstRange(of: end) {
                let head = String(decoding: received[..<found.lowerBound], as: UTF8.self)
                let status = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
                guard status.split(separator: " ").dropFirst().first == "101" else { break }
                return MCPWebSocket(descriptor: descriptor, leftover: Array(received[found.upperBound...]))
            }
            guard let count = mcpRead(descriptor, into: &chunk) else { break }
            received += chunk[0..<count]
        }
        mcpClose(descriptor)
        return nil
    }

    /// A text message to the server; false once the socket is shut.
    @discardableResult
    func send(_ text: String) -> Bool {
        deliver(MCPWebSocketFrames.Opcode.text, Array(text.utf8))
    }

    /// Both directions ended, which wakes the reader; it then closes, and
    /// `messages` finishes. The server takes that as the end of the call
    /// (for `approve`, the prompt withdrawn).
    func shut() {
        alive.withLock { isOpen in
            if isOpen { visor_shutdown(descriptor) }
        }
    }

    private func deliver(_ opcode: UInt8, _ payload: [UInt8]) -> Bool {
        let frame = MCPWebSocketFrames.frame(opcode, payload, mask: MCPWebSocketFrames.randomMask())
        return alive.withLock { isOpen in isOpen && mcpWriteAll(descriptor, frame) }
    }

    /// The reader: frames until the end, a message in pieces put together,
    /// pings answered, a close answered and taken as the end.
    private func read(_ leftover: [UInt8]) {
        var buffer = leftover
        var pieces: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65536)
        reading: while true {
            while true {
                switch MCPWebSocketFrames.read(buffer) {
                case .incomplete:
                    break
                case .invalid:
                    break reading
                case .frame(let frame, let taken):
                    buffer.removeFirst(taken)
                    switch frame.opcode {
                    case MCPWebSocketFrames.Opcode.text, MCPWebSocketFrames.Opcode.binary, MCPWebSocketFrames.Opcode.continuation:
                        pieces += frame.payload
                        if frame.final {
                            arrived.yield(String(decoding: pieces, as: UTF8.self))
                            pieces = []
                        }
                    case MCPWebSocketFrames.Opcode.ping:
                        _ = deliver(MCPWebSocketFrames.Opcode.pong, frame.payload)
                    case MCPWebSocketFrames.Opcode.close:
                        _ = deliver(MCPWebSocketFrames.Opcode.close, Array(frame.payload.prefix(2)))
                        break reading
                    default:
                        break
                    }
                    continue
                }
                break
            }
            guard let count = mcpRead(descriptor, into: &chunk) else { break }
            buffer += chunk[0..<count]
        }
        alive.withLock { isOpen in
            guard isOpen else { return }
            isOpen = false
            mcpClose(descriptor)
        }
        arrived.finish()
    }
}
