// What the host waits on, each on a thread of its own, handed to the main
// actor in order as streams: a descriptor's bytes, a listener's
// connections, a child's end.

import CVisorPOSIX
import Foundation

/// What `descriptor` gives until its end, which closes it (through
/// `outlet` when something also writes to it).
func chunks(of descriptor: Int32, closing outlet: Outlet? = nil) -> AsyncStream<Data> {
    let (stream, arrived) = AsyncStream.makeStream(of: Data.self)
    Thread.detachNewThread {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            arrived.yield(Data(buffer[0..<count]))
        }
        if let outlet { outlet.closeNow() } else { close(descriptor) }
        arrived.finish()
    }
    return stream
}

/// The connections a listening socket takes, for as long as it listens.
func connections(to listener: Int32) -> AsyncStream<Int32> {
    let (stream, arrived) = AsyncStream.makeStream(of: Int32.self)
    Thread.detachNewThread {
        while true {
            let connection = visor_accept(listener)
            if connection < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                break
            }
            arrived.yield(connection)
        }
        arrived.finish()
    }
    return stream
}

/// How a child ended, once it has.
func ending(of pid: Int32) async -> (status: Int32, signaled: Bool) {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            var status: Int32 = 0, signaled: Int32 = 0
            if visor_wait(pid, &status, &signaled) != 0 { continuation.resume(returning: (-1, false)); return }
            continuation.resume(returning: (status, signaled != 0))
        }
    }
}
