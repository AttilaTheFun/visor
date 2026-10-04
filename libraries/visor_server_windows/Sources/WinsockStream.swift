import Foundation
import VisorServer

/// A connection as the server sees it: read on a thread of its own and
/// handed over on the main actor in order, written on a queue of its own.
@MainActor
final class WinsockStream: ByteStream {
    private let socket: WinsockSocket
    private let writes = DispatchQueue(label: "visor.socket.write")

    init(_ socket: WinsockSocket) {
        self.socket = socket
    }

    func receive(_ chunk: @escaping @MainActor (Data?) -> Void) {
        let (chunks, arrived) = AsyncStream.makeStream(of: Data?.self)
        let socket = self.socket
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = receiveBytes(socket.handle, into: &buffer)
                guard count > 0 else { break }
                arrived.yield(Data(buffer[0..<count]))
            }
            socket.close()
            arrived.yield(nil)
            arrived.finish()
        }
        Task { @MainActor in
            for await data in chunks { chunk(data) }
        }
    }

    func send(_ data: Data, sent: (@MainActor () -> Void)?) {
        let socket = self.socket
        writes.async {
            socket.write(data)
            if let sent { Task { @MainActor in sent() } }
        }
    }

    /// After what was sent before it has gone out.
    func close() {
        let socket = self.socket
        writes.async { socket.shutdown() }
    }
}
