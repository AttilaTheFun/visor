// Ports on loopback for the tests, without a race: a listener at a port
// the system picks (port 0, read back), and a port held closed (bound,
// never listened on, not shared), so nothing answers there and no other
// listener can take it while it's held. Not a port picked at random:
// another test, in this process or a target run beside it, can pick the
// same one, or listen at one just let go.

import CAgentProxyPOSIX
import Foundation

enum LoopbackPorts {
    /// A socket listening on 127.0.0.1 at a port the system picked, and
    /// that port. Nil when it can't listen.
    static func listener() -> (socket: Int32, port: Int)? {
        let listener = agent_proxy_listen(0, 0)
        guard listener >= 0 else { return nil }
        guard let port = port(of: listener) else {
            close(listener)
            return nil
        }
        return (listener, port)
    }

    /// A port on 127.0.0.1 where a connection is refused until `release`:
    /// a socket bound there without SO_REUSEADDR and never listened on.
    static func closed() -> (port: Int, release: @Sendable () -> Void)? {
        #if canImport(Glibc)
        let holder = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let holder = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard holder >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(holder, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, let port = port(of: holder) else {
            close(holder)
            return nil
        }
        return (port, { close(holder) })
    }

    /// The port `socket` is bound to.
    private static func port(of socket: Int32) -> Int? {
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: bound.sin_port))
    }
}
