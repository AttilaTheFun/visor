import CVisorPOSIX
import Foundation
import VisorServer

/// A connection as the server sees it: what arrives, read on a thread of
/// its own and handed over on the main actor in order; what is sent,
/// written on a queue of its own.
@MainActor
final class POSIXSocketStream: ByteStream {
    private let socket: POSIXSocket
    private let writes = DispatchQueue(label: "visor.socket.write")

    init(_ socket: POSIXSocket) {
        self.socket = socket
    }

    var localAddress: String? {
        var buffer = [CChar](repeating: 0, count: 64)
        visor_local_address(self.socket.descriptor, &buffer, buffer.count)
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    func receive(_ chunk: @escaping @MainActor (Data?) -> Void) {
        let (chunks, arrived) = AsyncStream.makeStream(of: Data?.self)
        let socket = self.socket
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(socket.descriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
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
