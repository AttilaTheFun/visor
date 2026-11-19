// Where nftables' redirect brings every TCP connection the container makes
// (127.0.0.1 at one port): its original destination read back, a fake
// address turned back into its name, and the connection sent on through the
// relay as `CONNECT name:port`, then joined to it both ways. The kernel
// does the TCP; nothing here reads what goes through.

import CRelayClientPOSIX
import Foundation
import VisorAgentProxy

/// The redirected connections' listener.
public final class RedirectListener: Sendable {
    public let port: UInt16
    private let listener: Int32
    private let addresses: FakeAddresses
    private let relay: RelayDialer
    private let destination: @Sendable (Int32) -> (host: String, port: UInt16)?
    private let log: @Sendable (String) -> Void

    /// Listening on 127.0.0.1 at `port` (0: one the system picks). Nil if it
    /// can't be had. `destination` reads a connection's original destination
    /// (SO_ORIGINAL_DST unless a test says).
    public init?(port: UInt16, addresses: FakeAddresses, relay: RelayDialer,
                 destination: @escaping @Sendable (Int32) -> (host: String, port: UInt16)? = RedirectListener.originalDestination,
                 log: @escaping @Sendable (String) -> Void) {
        relay_client_ignore_broken_pipes()
        let listener = relay_client_listen(port, 0)
        guard listener >= 0 else { return nil }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        guard named == 0 else {
            close(listener)
            return nil
        }
        self.port = UInt16(bigEndian: bound.sin_port)
        self.listener = listener
        self.addresses = addresses
        self.relay = relay
        self.destination = destination
        self.log = log
    }

    public func start() {
        Thread.detachNewThread { [self] in
            while true {
                let connection = relay_client_accept(listener)
                if connection < 0 { return }
                Thread.detachNewThread { [self] in carry(connection) }
            }
        }
    }

    public func stop() {
        relay_client_shutdown(listener)
        close(listener)
    }

    /// Where a redirected connection was going.
    public static func originalDestination(_ connection: Int32) -> (host: String, port: UInt16)? {
        var host = [CChar](repeating: 0, count: 64)
        var port: UInt16 = 0
        guard relay_client_original_destination(connection, &host, host.count, &port) == 0 else { return nil }
        return (String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), port)
    }

    private func carry(_ connection: Int32) {
        guard let (address, port) = destination(connection) else {
            log("a connection with no original destination (not redirected): closed")
            close(connection)
            return
        }
        // To this listener itself, or loopback's: never relayed.
        if address.hasPrefix("127.") {
            close(connection)
            return
        }
        let host = addresses.name(for: address) ?? address
        guard let stream = relay.open(host: host, port: port, problem: { [log] in log($0) }) else {
            close(connection)
            return
        }
        Splice.join(connection, stream)
    }
}
