// `relay-client check` with no destination: whether the relay's socket
// reaches agent-proxy, by its health answer (the relay listener's `GET /`,
// 200 "agent-proxy"), with nothing resolved and nothing on the internet
// asked. The Sessions container's egress check (docs/containers.md): the
// container engine execs it in the guest once the container has booted, and
// shows "no egress" (refusing session starts) unless it passes.

import CAgentProxyPOSIX
import Foundation

/// The relay's own health, asked over its socket.
public enum RelayHealthCheck {
    /// What agent-proxy's relay listener answers `GET /` with.
    public static let answer = "agent-proxy"

    /// Whether `path` reaches agent-proxy: a line saying what happened, and
    /// whether it did. `timeout` is the seconds the answer may take.
    public static func run(path: String, timeout: Int32 = 10) -> (ok: Bool, line: String) {
        let stream = agent_proxy_connect_unix(path)
        guard stream >= 0 else { return (false, "the relay (\(path)) doesn't answer (errno \(errno))") }
        defer { close(stream) }
        agent_proxy_set_receive_timeout(stream, timeout)
        let request = Array("GET / HTTP/1.1\r\nHost: agent-proxy\r\nConnection: close\r\n\r\n".utf8)
        let sent = request.withUnsafeBytes { write(stream, $0.baseAddress, $0.count) }
        guard sent == request.count else { return (false, "the relay (\(path)) took no request") }
        var heard: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while heard.count < 64 << 10 {
            let count = buffer.withUnsafeMutableBytes { read(stream, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            heard += buffer[0..<count]
        }
        return judge(heard, path: path)
    }

    /// What an answer says: agent-proxy's health (200, its name as the
    /// body), or what came instead.
    static func judge(_ heard: [UInt8], path: String) -> (ok: Bool, line: String) {
        let text = String(decoding: heard, as: UTF8.self)
        guard !heard.isEmpty else {
            return (false, "the relay (\(path)) closed without an answer: agent-proxy isn't reached (no relay token, or no relay listener?)")
        }
        let status = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let body = text.range(of: "\r\n\r\n").map { String(text[$0.upperBound...]) } ?? ""
        guard status.hasPrefix("HTTP/1.1 200") || status.hasPrefix("HTTP/1.0 200"),
              body.trimmingCharacters(in: .whitespacesAndNewlines) == answer else {
            return (false, "the relay (\(path)) answered \"\(status)\", not agent-proxy's health")
        }
        return (true, "agent-proxy answers through the relay (\(path))")
    }
}
