// Two connections joined: the bytes each way as they come, until both
// have ended. The client proxy's, the egress proxy's tunnels, the
// dial-ins' and the forwards'. Moved from MultiPassBase.

import CAgentProxyPOSIX
import Foundation

/// Joining connections.
public enum Splice {
    /// Two connections joined, each way, until both have ended. When one
    /// way ends the other is given a few seconds to end too (an answer
    /// still on its way), then both are ended. Closes both.
    public static func join(_ client: Int32, _ server: Int32) {
        let ended = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            pump(from: client, to: server)
            ended.signal()
        }
        Thread.detachNewThread {
            pump(from: server, to: client)
            ended.signal()
        }
        ended.wait()
        if ended.wait(timeout: .now() + 5) == .timedOut {
            agent_proxy_shutdown(client)
            agent_proxy_shutdown(server)
            ended.wait()
        }
        close(client)
        close(server)
    }

    /// The bytes from one to the other as they come, until the one ends or
    /// the other stops taking them; then the other hears that no more is
    /// coming.
    static func pump(from source: Int32, to sink: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        reading: while true {
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            var sent = 0
            while sent < count {
                let wrote = buffer.withUnsafeBytes { write(sink, $0.baseAddress! + sent, count - sent) }
                if wrote <= 0 { break reading }
                sent += wrote
            }
        }
        agent_proxy_shutdown_write(sink)
    }
}
