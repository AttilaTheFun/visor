import CVisorPOSIX
import Foundation

/// The Runner's MCP proxy (docs/co-tenancy.md): every Visor server's MCP
/// servers are set to it, natively on loopback and from a container through
/// its network's gateway. A call to `/mcp/<name>` that carries a server's
/// token goes on to that endpoint with the secret headers the Runner keeps,
/// and its answer comes back as it comes (JSON, or SSE). No server holds a
/// secret header. Plain HTTP endpoints (on this computer, or its network).
/// On the same port, with the same tokens, `/apns/…` is the push proxy
/// (APNsProxy), when the Runner has one.
public final class MCPProxy: Sendable {
    /// The header a call carries its server's token in.
    public static let tokenHeader = "X-Visor-Proxy"

    /// An MCP server the Runner passes calls on to: its name, its address,
    /// its headers (a value may name the session, `$SESSION_ID`, which the
    /// calling server fills in), the names of those whose values are
    /// secrets, kept by the Runner, and the tools it keeps from servers.
    public struct Endpoint: Codable, Equatable, Sendable {
        public var name: String
        public var url: String
        public var headers: [String: String]
        public var secretHeaders: [String]
        /// Tools no server is given: left out of `tools/list`, and a call
        /// of one refused here, never passed on. One whose answer holds a
        /// credential (Keymaster's `github_token`): the container a server
        /// runs in is its agents' too, so what a server is given, an agent
        /// can read.
        public var withheldTools: [String]

        public init(name: String, url: String, headers: [String: String] = [:], secretHeaders: [String] = [], withheldTools: [String] = []) {
            self.name = name
            self.url = url
            self.headers = headers
            self.secretHeaders = secretHeaders
            self.withheldTools = withheldTools
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            url = try c.decode(String.self, forKey: .url)
            headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
            secretHeaders = try c.decodeIfPresent([String].self, forKey: .secretHeaders) ?? []
            withheldTools = try c.decodeIfPresent([String].self, forKey: .withheldTools) ?? []
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
    /// The push proxy, if this Runner has one (`/apns/…`).
    private let pushes: APNsProxy?

    /// Listening on `port` on every interface (the containers' network is
    /// one): a call without a server's token is refused. Nil when the port
    /// can't be had.
    public init?(port: UInt16, endpoints: @escaping @Sendable () -> [Endpoint], admits: @escaping @Sendable (String) -> Bool,
                 pushes: APNsProxy? = nil, secret: @escaping @Sendable (_ endpoint: String, _ header: String) -> String?) {
        visor_ignore_broken_pipes()
        let listener = visor_listen(port, 1)
        guard listener >= 0 else { return nil }
        self.port = port
        self.listener = listener
        self.endpoints = endpoints
        self.admits = admits
        self.secret = secret
        self.pushes = pushes
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

    static func reply(_ connection: Int32, _ answer: APNsProxy.Answer) {
        let head = "HTTP/1.1 \(answer.status == 0 ? 502 : answer.status) APNs\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(answer.body.count)\r\nConnection: close\r\n\r\n"
        send(connection, Data(head.utf8) + answer.body)
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
        guard var request = Self.read(client) else { return }
        guard let token = request.header(Self.tokenHeader), admits(token) else {
            return Self.reply(client, "401 Unauthorized", "No server's token for this proxy.")
        }
        if request.path.hasPrefix("/apns/") {
            guard let pushes else { return Self.reply(client, "404 Not Found", "This Runner proxies no pushes.") }
            return Self.reply(client, pushes.answer(method: request.method, path: request.path, headers: request.headers, body: request.body))
        }
        let name = request.path.hasPrefix("/mcp/") ? String(request.path.dropFirst(5).prefix { $0 != "?" && $0 != "/" }) : ""
        guard let endpoint = endpoints().first(where: { $0.name == name }) else { return Self.reply(client, "404 Not Found", "No MCP server \(name).") }
        guard let url = URLComponents(string: endpoint.url), url.scheme == "http", let host = url.host else {
            return Self.reply(client, "502 Bad Gateway", "\(endpoint.url) is not a plain HTTP address.")
        }
        // A tool kept from servers: a call of it refused here, and a tool
        // list given without it. What goes on is what was checked.
        let withheld = Set(endpoint.withheldTools)
        var listing = false
        if !withheld.isEmpty {
            switch Self.checked(request, withheld: withheld) {
            case .refused(let error): return Self.send(client, Self.jsonAnswer(error))
            case .passed(let body, let lists):
                request.body = body
                listing = lists
            }
        }
        let port = url.port ?? 80
        let upstream = visor_connect_tcp(host, UInt16(port))
        guard upstream >= 0 else { return Self.reply(client, "502 Bad Gateway", "\(endpoint.url) doesn't answer.") }
        defer { close(upstream) }
        let path = (url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath) + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
        var head = "\(request.method) \(path) HTTP/1.1\r\n"
        for header in forwarded(request, to: endpoint, host: "\(host):\(port)") { head += "\(header.name): \(header.value)\r\n" }
        Self.send(upstream, Data((head + "\r\n").utf8) + request.body)
        // Its answer, as it comes, to its end (Connection: close); a tool
        // list from an endpoint that withholds tools whole, without them.
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        var held = Data()
        while true {
            let count = buffer.withUnsafeMutableBytes { Foundation.read(upstream, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            if listing { held.append(contentsOf: buffer[0..<count]) } else { Self.send(client, Data(buffer[0..<count])) }
        }
        if listing { Self.send(client, Self.withoutTools(withheld, in: held)) }
    }

    /// A request to an endpoint that withholds tools, checked.
    enum Checked: Equatable {
        /// Its body as it goes on, and whether it asks for the tools.
        case passed(Data, listsTools: Bool)
        /// The JSON-RPC error to answer with.
        case refused(Data)
    }

    /// A request to an endpoint that withholds tools, failing closed: a
    /// POST's body must be a JSON-RPC message or a batch of them (else
    /// -32600), and a `tools/call` must name, as a plain string, a tool not
    /// withheld (else -32601). What passes goes on as read here, written
    /// again, so the endpoint reads only what was checked: no key twice,
    /// nothing two parsers read differently. Another method (an MCP
    /// session's GET or DELETE) passes only with no body.
    static func checked(_ request: Request, withheld: Set<String>) -> Checked {
        let notMessages = error(id: nil, -32600, "Only JSON-RPC messages go to this endpoint.")
        guard request.method == "POST" else { return request.body.isEmpty ? .passed(Data(), listsTools: false) : .refused(notMessages) }
        let parsed = try? JSONSerialization.jsonObject(with: request.body)
        var messages: [[String: Any]] = []
        if let one = parsed as? [String: Any] {
            messages = [one]
        } else if let batch = parsed as? [Any], !batch.isEmpty {
            messages = batch.compactMap { $0 as? [String: Any] }
            if messages.count != batch.count { messages = [] }
        }
        guard !messages.isEmpty, let parsed, let body = try? JSONSerialization.data(withJSONObject: parsed) else { return .refused(notMessages) }
        for message in messages where message["method"] as? String == "tools/call" {
            guard let name = (message["params"] as? [String: Any])?["name"] as? String, !withheld.contains(name) else {
                return .refused(error(id: message["id"], -32601, "This tool is kept from Visor's servers."))
            }
        }
        let lists = messages.count == 1 && messages[0]["method"] as? String == "tools/list"
        return .passed(body, listsTools: lists)
    }

    /// A JSON-RPC error answering the message `id`.
    static func error(id: Any?, _ code: Int, _ message: String) -> Data {
        let error: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
        return (try? JSONSerialization.data(withJSONObject: error)) ?? Data()
    }

    /// An HTTP answer of JSON.
    static func jsonAnswer(_ body: Data) -> Data {
        Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
    }

    /// An endpoint's whole HTTP answer to `tools/list`, without the tools
    /// withheld: its JSON body rewritten, its length set again. Any other
    /// answer (an error, a stream) as it came.
    static func withoutTools(_ withheld: Set<String>, in answer: Data) -> Data {
        let blank = Data("\r\n\r\n".utf8)
        guard let end = answer.range(of: blank) else { return answer }
        let head = String(decoding: answer[..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let headers = lines.dropFirst()
        func header(_ name: String) -> String? {
            headers.first { $0.lowercased().hasPrefix(name + ":") }.map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
        }
        guard header("content-type")?.lowercased().hasPrefix("application/json") == true, header("transfer-encoding") == nil,
              var message = (try? JSONSerialization.jsonObject(with: answer[end.upperBound...])) as? [String: Any],
              var result = message["result"] as? [String: Any], let tools = result["tools"] as? [[String: Any]] else { return answer }
        result["tools"] = tools.filter { ($0["name"] as? String).map(withheld.contains) != true }
        message["result"] = result
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return answer }
        var kept = [lines[0]] + headers.filter { !$0.lowercased().hasPrefix("content-length:") }
        kept.append("Content-Length: \(body.count)")
        return Data((kept.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
    }
}
