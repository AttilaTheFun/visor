// `relay-client check <host>:<port> [--send <text>]`: whether a name
// resolves and a connection to it goes through, as any program in the
// container would make it (the system's resolver, then a plain TCP
// connect), with what came back for what was sent.

import CRelayClientPOSIX
import Foundation

/// One connection, made as a program would.
public enum ConnectionCheck {
    /// What happened, a line each; nil for the host:port that can't be read.
    public static func run(_ target: String, send: String?, timeout: Int32 = 10, settle: Int = 2) -> (ok: Bool, lines: [String])? {
        guard let colon = target.lastIndex(of: ":"), let port = UInt16(target[target.index(after: colon)...]), port > 0 else { return nil }
        let host = String(target[..<colon])
        var text = [CChar](repeating: 0, count: 64)
        let socket = relay_client_resolve_connect(host, port, timeout, &text, text.count)
        guard socket != -2 else { return (false, ["\(host): not resolved"]) }
        let address = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var lines = ["\(host) is \(address)"]
        guard socket >= 0 else { return (false, lines + ["\(target): not connected (errno \(errno))"]) }
        defer { close(socket) }
        guard let send else {
            // In the container, the redirect listener takes every connection
            // at once and closes it when the relay can't reach the far end:
            // so a connection closed within `settle` was never through.
            switch settled(socket, seconds: settle) {
            case .closed: return (false, lines + ["\(target): not connected (closed at once: the relay couldn't reach it)"])
            case .open: return (true, lines + ["connected to \(target)"])
            }
        }
        lines.append("connected to \(target)")
        let bytes = Array(send.utf8)
        _ = bytes.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { read(socket, $0.baseAddress, $0.count) }
        guard count > 0 else { return (false, lines + ["nothing came back"]) }
        return (true, lines + ["heard: " + String(decoding: buffer[0..<count], as: UTF8.self)])
    }

    enum Settled { case open, closed }

    /// Whether `socket` is still open after `seconds`: closed (an end of
    /// file, or an error) if it ends first; open if it is still there, or
    /// something came to read.
    static func settled(_ socket: Int32, seconds: Int) -> Settled {
        var wait = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var byte: UInt8 = 0
        let count = recv(socket, &byte, 1, Int32(MSG_PEEK))
        if count > 0 { return .open }
        if count == 0 { return .closed }
        return errno == EAGAIN || errno == EWOULDBLOCK ? .open : .closed
    }
}
