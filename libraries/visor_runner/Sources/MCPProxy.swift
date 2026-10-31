import CVisorPOSIX
import Foundation

/// The Runner's MCP proxy (docs/co-tenancy.md): every Visor server's MCP
/// servers are set to it, natively on loopback and from a container through
/// its network's gateway. A call to `/mcp/<name>` that carries a server's
/// token goes on to that endpoint with the secret headers the Runner keeps,
/// and its answer comes back as it comes (JSON, or SSE). No server holds a
/// secret header. Plain HTTP endpoints (on this computer, or its network).
public final class MCPProxy: Sendable {
    /// The header a call carries its server's token in.
    public static let tokenHeader = "X-Visor-Proxy"

    /// An MCP server the Runner passes calls on to: its name, its address,
    /// its headers (a value may name the session, `$SESSION_ID`, which the
    /// calling server fills in) and the names of those whose values are
    /// secrets, kept by the Runner.
    public struct Endpoint: Equatable, Sendable {
        public var name: String
        public var url: String
        public var headers: [String: String]
        public var secretHeaders: [String]

        public init(name: String, url: String, headers: [String: String] = [:], secretHeaders: [String] = []) {
            self.name = name
            self.url = url
            self.headers = headers
            self.secretHeaders = secretHeaders
        }
    }

    public let port: UInt16
    private let listener: Int32
    /// The endpoints as they are set now.
    private let endpoints: @Sendable () -> [Endpoint]
    /// Whether a token is one of a server's.
    private let admits: @Sendable (String) -> Bool
    /// A secret header's value, by its endpoint and name.
    private let secret: @Sendable (_ endpoint: String, _ header: String) -> String?

    /// Listening on `port` on every interface (the containers' network is
    /// one): a call without a server's token is refused. Nil when the port
    /// can't be had.
    public init?(port: UInt16, endpoints: @escaping @Sendable () -> [Endpoint], admits: @escaping @Sendable (String) -> Bool,
                 secret: @escaping @Sendable (_ endpoint: String, _ header: String) -> String?) {
        visor_ignore_broken_pipes()
        let listener = visor_listen(port, 1)
        guard listener >= 0 else { return nil }
        self.port = port
        self.listener = listener
        self.endpoints = endpoints
        self.admits = admits
        self.secret = secret
    }

    public func start() {
        Thread.detachNewThread { [self] in
            while true {
                let client = visor_accept(listener)
                if client < 0 { return }
                Thread.detachNewThread { [self] in
                    answer(client)
                    close(client)
                }
            }
        }
    }

    public func stop() {
        visor_shutdown(listener)
        close(listener)
    }

    /// A request as it came: its line, its headers (as given), its body.
    struct Request {
        var method: String
        var path: String
        var headers: [(name: String, value: String)]
        var body: Data

        func header(_ name: String) -> String? { headers.first { $0.name.lowercased() == name.lowercased() }?.value }
    }

    /// The request on `connection`, up to its body's length; nil for one
    /// that isn't HTTP.
    static func read(_ connection: Int32) -> Request? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 << 10)
        let blank = Data("\r\n\r\n".utf8)
        while data.range(of: blank) == nil {
            let count = buffer.withUnsafeMutableBytes { Foundation.read(connection, $0.baseAddress, $0.count) }
            if count <= 0 || data.count > 1 << 20 { return nil }
            data.append(contentsOf: buffer[0..<count])
        }
        guard let end = data.range(of: blank) else { return nil }
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let headers = lines.dropFirst().compactMap { line -> (name: String, value: String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        var body = Data(data[end.upperBound...])
        let length = headers.first { $0.name.lowercased() == "content-length" }.flatMap { Int($0.value) } ?? 0
        while body.count < length {
            let count = buffer.withUnsafeMutableBytes { Foundation.read(connection, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            body.append(contentsOf: buffer[0..<count])
        }
        return Request(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body)
    }

    static func reply(_ connection: Int32, _ status: String, _ text: String) {
        let body = Data(text.utf8)
        send(connection, Data("HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body)
    }

    static func send(_ connection: Int32, _ data: Data) {
        var sent = 0
        while sent < data.count {
            let wrote = data.withUnsafeBytes { Foundation.write(connection, $0.baseAddress! + sent, data.count - sent) }
            if wrote <= 0 { return }
            sent += wrote
        }
    }

    /// The headers a call goes on with: its own, but those of the hop and
    /// the token, and the endpoint's secret ones.
    func forwarded(_ request: Request, to endpoint: Endpoint, host: String) -> [(name: String, value: String)] {
        let dropped: Set<String> = ["host", "connection", "content-length", "transfer-encoding", "keep-alive", Self.tokenHeader.lowercased()]
        var headers = request.headers.filter { !dropped.contains($0.name.lowercased()) }
        headers.append(("Host", host))
        for name in endpoint.secretHeaders {
            if let value = secret(endpoint.name, name) { headers.append((name, value)) }
        }
        headers.append(("Content-Length", String(request.body.count)))
        headers.append(("Connection", "close"))
        return headers
    }

    private func answer(_ client: Int32) {
        guard let request = Self.read(client) else { return }
        guard let token = request.header(Self.tokenHeader), admits(token) else {
            return Self.reply(client, "401 Unauthorized", "No server's token for this proxy.")
        }
        let name = request.path.hasPrefix("/mcp/") ? String(request.path.dropFirst(5).prefix { $0 != "?" && $0 != "/" }) : ""
        guard let endpoint = endpoints().first(where: { $0.name == name }) else { return Self.reply(client, "404 Not Found", "No MCP server \(name).") }
        guard let url = URLComponents(string: endpoint.url), url.scheme == "http", let host = url.host else {
            return Self.reply(client, "502 Bad Gateway", "\(endpoint.url) is not a plain HTTP address.")
        }
        let port = url.port ?? 80
        let upstream = visor_connect_tcp(host, UInt16(port))
        guard upstream >= 0 else { return Self.reply(client, "502 Bad Gateway", "\(endpoint.url) doesn't answer.") }
        defer { close(upstream) }
        let path = (url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath) + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
        var head = "\(request.method) \(path) HTTP/1.1\r\n"
        for header in forwarded(request, to: endpoint, host: "\(host):\(port)") { head += "\(header.name): \(header.value)\r\n" }
        Self.send(upstream, Data((head + "\r\n").utf8) + request.body)
        // Its answer, as it comes, to its end (Connection: close).
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = buffer.withUnsafeMutableBytes { Foundation.read(upstream, $0.baseAddress, $0.count) }
            if count <= 0 { return }
            Self.send(client, Data(buffer[0..<count]))
        }
    }
}
