// A small HTTP/1.1 server (Network.framework, raw TCP) for the REST side of
// the protocol: one request per connection is all the clients need. JSON
// in and out, a bearer password, CORS for the web client (including
// Chrome's private-network preflight). Sits beside the WebSocket listener;
// Tailscale Serve fronts both on 443 (/api → here).

import Foundation
import Network

@MainActor
public final class HTTPServer {
    private var listener: NWListener?
    private let port: UInt16
    /// Answers a request, now or later: a long poll holds its answer
    /// until there is something to say.
    private let handler: (HTTPRequest, @escaping @MainActor (HTTPResponse) -> Void) -> Void

    public init(port: UInt16, handler: @escaping (HTTPRequest, @escaping @MainActor (HTTPResponse) -> Void) -> Void) {
        self.port = port
        self.handler = handler
    }

    /// Loopback only: the road in is Tailscale Serve, which proxies from
    /// this Mac and names the caller in headers nobody else can add.
    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        // The listener's queue is the main one.
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        read(connection, after: Data())
    }

    /// Reads on from what has been received until the request is whole,
    /// then has it answered.
    private func read(_ connection: NWConnection, after received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            let failed = error != nil
            // The connection's queue is the main one.
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = received
                if let data { buffer.append(data) }
                if let request = Self.parse(buffer) {
                    if request.method == "OPTIONS" {
                        self.write(HTTPResponse(204), to: connection)
                    } else {
                        self.handler(request) { [weak self] response in self?.write(response, to: connection) }
                    }
                } else if failed || complete {
                    connection.cancel()
                } else {
                    self.read(connection, after: buffer)
                }
            }
        }
    }

    /// A complete request from the bytes so far, or nil while more is needed.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let body = String(data: data[bodyStart..<(bodyStart + length)], encoding: .utf8) ?? ""
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body)
    }

    private func write(_ response: HTTPResponse, to connection: NWConnection) {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed", 503: "Service Unavailable"][response.status] ?? "OK"
        let body = Data(response.body.utf8)
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        head += "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\n"
        head += "Access-Control-Allow-Headers: Authorization, Content-Type\r\nAccess-Control-Allow-Private-Network: true\r\n"
        head += "Access-Control-Max-Age: 600\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
