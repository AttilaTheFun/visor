// A small HTTP/1.1 server (Network.framework, raw TCP) for the REST side of
// the protocol: one request per connection is all the clients need. JSON
// in and out, a bearer password, CORS for the web client (including
// Chrome's private-network preflight). Sits beside the WebSocket listener;
// Tailscale Serve fronts both on 443 (/api → here).

import Foundation
import Network

public struct HTTPRequest {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: String

    /// The bearer token; "" for a bare `Bearer` (no password).
    public var authorization: String? {
        guard let value = headers["authorization"] else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.first?.lowercased() == "bearer" else { return nil }
        return parts.count == 2 ? String(parts[1]) : ""
    }
}

public struct HTTPResponse {
    public var status: Int
    public var body: String
    public init(_ status: Int, _ body: String = "") { self.status = status; self.body = body }
    public static func json(_ text: String) -> HTTPResponse { HTTPResponse(200, text) }
}

@MainActor
public final class HTTPServer {
    private var listener: NWListener?
    private let port: UInt16
    /// Answers a request, now or later: a long poll holds its answer
    /// until there is something to say.
    private let handler: (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void

    public init(port: UInt16, handler: @escaping (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void) {
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
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
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
        var buffer = Data()
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let data { buffer.append(data) }
                    if let request = Self.parse(buffer) {
                        if request.method == "OPTIONS" {
                            self.write(HTTPResponse(204), to: connection)
                        } else {
                            self.handler(request) { [weak self] response in
                                Task { @MainActor in self?.write(response, to: connection) }
                            }
                        }
                    } else if error != nil || complete {
                        connection.cancel()
                    } else {
                        read()
                    }
                }
            }
        }
        read()
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
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed"][response.status] ?? "OK"
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
