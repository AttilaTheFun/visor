// A small HTTP/1.1 server for the REST side of the protocol: one request
// per connection is all the clients need. JSON in and out, a bearer
// password, CORS for the web client (including Chrome's private-network
// preflight). Sits beside the WebSocket listener; the road in fronts both
// on 443 (/api → here). Read and written here over the system's bytes.

import Foundation

@MainActor
public final class HTTPServer {
    private var listener: (any LoopbackListener)?
    private let port: UInt16
    /// Answers a request, now or later: a long poll holds its answer
    /// until there is something to say.
    private let handler: (HTTPRequest, @escaping @MainActor (HTTPResponse) -> Void) -> Void

    public init(port: UInt16, handler: @escaping (HTTPRequest, @escaping @MainActor (HTTPResponse) -> Void) -> Void) {
        self.port = port
        self.handler = handler
    }

    /// Loopback only: the road in is the exposure (Tailscale Serve), which
    /// proxies from this computer and names the caller in headers nobody
    /// else can add.
    public func start() throws {
        listener = try ServerPlatform.current.listening.listen(port: port) { [weak self] stream in
            self?.accept(stream)
        }
    }

    public func stop() {
        listener?.stop()
        listener = nil
    }

    private func accept(_ stream: any ByteStream) {
        let exchange = Exchange()
        stream.receive { [weak self] chunk in
            guard let self, !exchange.answered else { return }
            guard let chunk else { return stream.close() }
            exchange.received.append(chunk)
            guard let request = Self.parse(exchange.received) else { return }
            exchange.answered = true
            if request.method == "OPTIONS" {
                self.write(HTTPResponse(204), to: stream)
            } else {
                self.handler(request) { [weak self] response in self?.write(response, to: stream) }
            }
        }
    }

    /// Where the head of a request ends (the blank line's first byte), or
    /// nil while it is still arriving.
    nonisolated static func headerEnd(_ bytes: some Collection<UInt8>) -> Int? {
        let bytes = Array(bytes)
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4) where bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
            return index
        }
        return nil
    }

    /// The header lines of a request's head (its first line skipped), by
    /// lower-cased name.
    nonisolated static func headers(_ head: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return headers
    }

    /// A complete request from the bytes so far, or nil while more is needed.
    nonisolated static func parse(_ data: Data) -> HTTPRequest? {
        let bytes = [UInt8](data)
        guard let end = headerEnd(bytes) else { return nil }
        let head = String(decoding: bytes[..<end], as: UTF8.self)
        let requestLine = (head.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let headers = headers(head)
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end + 4
        guard bytes.count - bodyStart >= length else { return nil }
        let body = String(decoding: bytes[bodyStart..<(bodyStart + length)], as: UTF8.self)
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body)
    }

    private func write(_ response: HTTPResponse, to stream: any ByteStream) {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed", 503: "Service Unavailable"][response.status] ?? "OK"
        let body = Data(response.body.utf8)
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        head += "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\n"
        head += "Access-Control-Allow-Headers: Authorization, Content-Type\r\nAccess-Control-Allow-Private-Network: true\r\n"
        head += "Access-Control-Max-Age: 600\r\n\r\n"
        stream.send(Data(head.utf8) + body) { stream.close() }
    }
}

/// One request's bytes as they arrive, and whether it has been answered.
@MainActor
private final class Exchange {
    var received = Data()
    var answered = false
}
