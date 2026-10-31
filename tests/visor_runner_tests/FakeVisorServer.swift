import CVisorPOSIX
import Foundation
import Synchronization

/// The Visor server in the container, played here: once the fake
/// `visor-server start` has run (its port in `started`), a listener on
/// loopback that answers `/api/hello`, `/api/code` and `PUT /api/mcp` (its
/// body kept in `mcp-put.json`) to the password the fake `visor-server
/// password` kept, and 401 to anyone else.
final class FakeVisorServer: Sendable {
    let folder: URL
    private let listener = Mutex<Int32>(-1)
    private let ended = Mutex(false)

    init(folder: URL) {
        self.folder = folder
        Thread.detachNewThread { [self] in
            while !ended.withLock({ $0 }) {
                if let text = try? String(contentsOf: folder.appendingPathComponent("started"), encoding: .utf8),
                   let port = UInt16(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    serve(port)
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    private func serve(_ port: UInt16) {
        let socket = visor_listen(port, 0)
        guard socket >= 0 else { return }
        listener.withLock { $0 = socket }
        while true {
            let connection = visor_accept(socket)
            if connection < 0 { return }
            Thread.detachNewThread { [self] in answer(connection) }
        }
    }

    private func answer(_ connection: Int32) {
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            request.append(contentsOf: buffer[0..<count])
        }
        let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        if let length = lines.first(where: { $0.lowercased().hasPrefix("content-length:") }).flatMap({ Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) }),
           let end = request.range(of: Data("\r\n\r\n".utf8)) {
            var body = Data(request[end.upperBound...])
            while body.count < length {
                let count = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
                if count <= 0 { break }
                body.append(contentsOf: buffer[0..<count])
            }
            if path == "/api/mcp" { try? body.write(to: folder.appendingPathComponent("mcp-put.json")) }
        }
        let password = (try? String(contentsOf: folder.appendingPathComponent("password"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let authorized = lines.contains { $0.lowercased() == "authorization: bearer \(password)".lowercased() }
        let bodies = ["/api/hello": #"{"type":"hello","version":"0.45.0"}"#, "/api/code": #"{"type":"code","text":"visor-code"}"#,
                      "/api/mcp": #"{"endpoints":[]}"#]
        let body = authorized ? bodies[path] ?? #"{"type":"error"}"# : ""
        let response = "HTTP/1.1 \(authorized ? "200 OK" : "401 Unauthorized")\r\nContent-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n" + body
        _ = Array(response.utf8).withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
        close(connection)
    }

    func stop() {
        ended.withLock { $0 = true }
        let socket = listener.withLock { $0 }
        if socket >= 0 {
            visor_shutdown(socket)
            close(socket)
        }
    }
}

/// A port on loopback, likely free: from the high range, at random.
func freePort() -> Int { Int.random(in: 20000...45000) }
