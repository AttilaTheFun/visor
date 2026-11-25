// The native sessions' MCP proxy (Logan, 2026-11-18: MultiPass is archived once nothing needs it): moved from
// MultiPass's MCPProxy. Every native Visor session's MCP servers point here, on loopback (Visor's `mcpEndpoints`,
// 127.0.0.1:7439/mcp/<name>). A call carrying the sessions' token (`X-Visor-Proxy`) goes on to the named endpoint with
// the secret headers agent-proxy keeps (its Keychain's, never a session's), and its answer comes back as it comes
// (JSON, or SSE). Containers don't come this way: theirs is the relay listener's `/mcp/<name>` (MCPAnswering).
// In Visor (moved from Shireworks' v0.15.1, 19 Nov 2026) its upstreams are ServerSettings' `agentProxy.mcp`, its
// token and their secret headers Visor's secrets.
// From 0.66 a name may also be answered in-process (InProcessMCP: gh_mcp, folded in at `/mcp/gh`), where no upstream
// of that name is configured: an upstream wins, so moving gh_mcp from its own listener (7470) in is a settings change.
// From 0.72.1 the Sessions container's agents reach it too, through the relay's dial-in `mcp.agent.internal:80`
// (DialIn.passThrough), with no sessions' token of theirs: a call shows its agent's own token (`agentSession`, Visor's
// container runner: a JWT for `visor.runner-agent`, minted for MCP alone, naming an agent running now), and goes on as
// that token's session (CLIENT_ID, and an upstream's `$SESSION_ID` headers, are agent-proxy's to set, never the
// caller's word). Only on the servers containers are given (`containerServers`: Nimbus's, Logan, 25 Nov 2026); any
// other path is refused them (403). gh in a container is the gh CLI through the GitHub gate, oss is retired, and
// Shireworks' is Nimbus's now.

import CAgentProxyPOSIX
import Foundation

public final class NativeMCPProxy: Sendable {
    /// The header a call carries the sessions' token in, as MultiPass read it.
    public static let tokenHeader = "X-Visor-Proxy"
    /// The servers the Sessions container's agents are given, by name (`/mcp/<name>`): Nimbus's alone (Logan, 25 Nov
    /// 2026: "agents can talk to the visor and nimbus mcps", gh the CLI through the GitHub gate, oss gone). A
    /// container agent's call to any other is refused, and its Claude is told of no other (ContainerClaudeMCP).
    public static let containerServers: Set<String> = ["nimbus"]

    /// An MCP server calls are passed on to: its name (`/mcp/<name>`), its plain HTTP address, its headers, the names
    /// of those whose values are secrets (kept by agent-proxy), and the tools it keeps from sessions.
    public struct Endpoint: Codable, Equatable, Sendable {
        public var name: String
        public var url: String
        public var headers: [String: String]
        public var secretHeaders: [String]
        /// Tools no session is given: left out of `tools/list`, and a call of one refused here, never passed on.
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
    private let endpoints: @Sendable () -> [Endpoint]
    /// Whether a token is the sessions'.
    private let admits: @Sendable (String) -> Bool
    /// A secret header's value, by its endpoint and name.
    private let secret: @Sendable (_ endpoint: String, _ header: String) -> String?
    /// The most calls answered at once (a thread each), as the relay caps its streams; more are refused with 503.
    public let maxConnections: Int
    /// The calls being answered.
    private let open = Locked(0)
    /// The MCP servers answered here, in this process, by name (`/mcp/<name>`), where no upstream has that name.
    private let inProcess: [String: any InProcessMCP]
    /// The tools each of those keeps from the sessions, as an upstream's `withheldTools`.
    private let inProcessWithheld: [String: Set<String>]
    /// The session a container agent's own token acts as, while its agent runs (nil for any other token). None: only
    /// the sessions' token is taken.
    private let agentSession: (@Sendable (String) async -> String?)?
    /// The servers a container agent's call may reach (`containerServers` unless a test says).
    private let agentServers: Set<String>
    /// How long a call waits to hear whether a token is a container agent's.
    static let agentSessionWithin: DispatchTimeInterval = .seconds(10)

    public static let defaultMaxConnections = 64

    /// Listening on loopback `port` alone: a call without the sessions' token, or a container agent's own (`agentSession`
    /// names its session), is refused. Nil when the port can't be had.
    public init?(port: UInt16, endpoints: @escaping @Sendable () -> [Endpoint], admits: @escaping @Sendable (String) -> Bool,
                 secret: @escaping @Sendable (_ endpoint: String, _ header: String) -> String?,
                 inProcess: [String: any InProcessMCP] = [:], inProcessWithheld: [String: [String]] = [:],
                 agentSession: (@Sendable (String) async -> String?)? = nil,
                 agentServers: Set<String> = NativeMCPProxy.containerServers,
                 maxConnections: Int = NativeMCPProxy.defaultMaxConnections) {
        agent_proxy_ignore_broken_pipes()
        let listener = agent_proxy_listen(port, 0)
        guard listener >= 0 else { return nil }
        self.port = port
        self.listener = listener
        self.endpoints = endpoints
        self.admits = admits
        self.secret = secret
        self.inProcess = inProcess
        self.inProcessWithheld = inProcessWithheld.mapValues(Set.init)
        self.agentSession = agentSession
        self.agentServers = agentServers
        self.maxConnections = maxConnections
    }

    public func start() {
        Thread.detachNewThread { [self] in
            while true {
                let client = agent_proxy_accept(listener)
                if client < 0 { return }
                guard opened() else {
                    Self.reply(client, "503 Service Unavailable", "Too many calls at once.")
                    close(client)
                    continue
                }
                Thread.detachNewThread { [self] in
                    agent_proxy_set_receive_timeout(client, 30)
                    answer(client)
                    close(client)
                    closed()
                }
            }
        }
    }

    /// One more call counted, if there's room for it.
    private func opened() -> Bool {
        open.withLock { open in
            guard open < maxConnections else { return false }
            open += 1
            return true
        }
    }

    private func closed() {
        open.withLock { $0 -= 1 }
    }

    public func stop() {
        agent_proxy_shutdown(listener)
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

    /// The most a call's head and body may be.
    static let maxHead = 1 << 20
    static let maxBody = 8 << 20

    /// The request on `connection`, up to its body's length; nil for one that isn't HTTP, or is too large.
    static func read(_ connection: Int32) -> Request? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 << 10)
        let blank = Data("\r\n\r\n".utf8)
        while data.range(of: blank) == nil {
            let count = buffer.withUnsafeMutableBytes { Foundation.read(connection, $0.baseAddress, $0.count) }
            if count <= 0 || data.count > maxHead { return nil }
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
        guard length <= maxBody else { return nil }
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

    /// The headers a call goes on with: its own (a session sends its plain ones, CLIENT_ID among them), but those of
    /// the hop, the token and any named as the endpoint's plain or secret ones (the caller's own never sits beside
    /// agent-proxy's), then the endpoint's plain ones (Visor's settings name them), then its secret ones. A plain one
    /// whose value names the session (`$SESSION_ID`, as MultiPass's runner.json kept CLIENT_ID) is the session's to
    /// send, filled in by Visor's server: it neither stands in for the session's nor goes on as it's written. For a
    /// container agent's call (`session`, its token's), those are agent-proxy's to fill: `$SESSION_ID` its session, and
    /// one naming anything else of the session (its title, its repository) left out, the caller's own never sent on.
    func forwarded(_ request: Request, to endpoint: Endpoint, host: String, session: String? = nil) -> [(name: String, value: String)] {
        var plain = endpoint.headers.filter { !$0.value.contains("$SESSION_") }
        var sessions: [String] = []
        if let session {
            let named = endpoint.headers.filter { $0.value.contains("$SESSION_") }
            sessions = named.keys.map { $0.lowercased() }
            for (name, value) in named {
                let filled = value.replacingOccurrences(of: "$SESSION_ID", with: session)
                if !filled.contains("$SESSION_") { plain[name] = filled }
            }
        }
        let dropped = Set(["host", "connection", "content-length", "transfer-encoding", "keep-alive", Self.tokenHeader.lowercased()]
            + endpoint.secretHeaders.map { $0.lowercased() } + plain.keys.map { $0.lowercased() } + sessions)
        var headers = request.headers.filter { !dropped.contains($0.name.lowercased()) }
        headers.append(("Host", host))
        for (name, value) in plain.sorted(by: { $0.key < $1.key }) where !value.contains(where: \.isNewline) {
            headers.append((name, value))
        }
        for name in endpoint.secretHeaders {
            if let value = secret(endpoint.name, name) { headers.append((name, value)) }
        }
        headers.append(("Content-Length", String(request.body.count)))
        headers.append(("Connection", "close"))
        return headers
    }

    private func answer(_ client: Int32) {
        guard var request = Self.read(client) else { return }
        guard let token = request.header(Self.tokenHeader) else {
            return Self.reply(client, "401 Unauthorized", "No sessions' token for this proxy.")
        }
        // The sessions' token (a native session's call, through Visor's server), else a container agent's own.
        var session: String?
        if !admits(token) {
            guard let agents = agentsSession(of: token) else {
                return Self.reply(client, "401 Unauthorized", "No sessions' token for this proxy.")
            }
            // A container's agent reaches the servers it's given alone.
            guard agentServers.contains(Self.serverName(request.path)) else {
                return Self.reply(client, "403 Forbidden", "This MCP server isn't one the Sessions container's agents are given.")
            }
            session = agents
            request = Self.asSession(request, agents)
        }
        // Bodies are read by Content-Length alone: a chunked one would go on cut short.
        guard request.header("transfer-encoding") == nil else {
            return Self.reply(client, "411 Length Required", "Send the body with a Content-Length.")
        }
        answerMCP(client, request, session: session)
    }

    /// The session `token` acts as, when it's a container agent's own (`agentSession` says, on a task of its own while
    /// this call's thread waits, at most `agentSessionWithin`); nil for any other, or with nothing to ask.
    private func agentsSession(of token: String) -> String? {
        guard let agentSession, Self.isJWTShaped(token) else { return nil }
        let found = Locked<String?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task {
            let session = await agentSession(token)
            found.withLock { $0 = session }
            done.signal()
        }
        guard done.wait(timeout: .now() + Self.agentSessionWithin) == .success else { return nil }
        return found.withLock { $0 }
    }

    /// The server a call's path names: `/mcp/<name>`'s name, up to a `?` or `/`; "" for any other path.
    static func serverName(_ path: String) -> String {
        path.hasPrefix("/mcp/") ? String(path.dropFirst(5).prefix { $0 != "?" && $0 != "/" }) : ""
    }

    /// Whether `token` is shaped as a JWT (three parts, none empty): only such a token is asked about.
    static func isJWTShaped(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty }
    }

    /// A container agent's call, as its token's `session`'s: whatever CLIENT_ID it sent (in any case, or as CLIENT-ID)
    /// taken off, and its session's own put in its place, so gh_mcp, and an upstream, know it by its token alone.
    static func asSession(_ request: Request, _ session: String) -> Request {
        var request = request
        request.headers.removeAll { $0.name.lowercased().replacingOccurrences(of: "_", with: "-") == "client-id" }
        request.headers.append((name: "CLIENT_ID", value: session))
        return request
    }

    /// A call to `/mcp/<name>`: passed on to that MCP server with its secret headers, a withheld tool refused; or, with
    /// no upstream of that name, answered by the one served here of that name. `session`: a container agent's call, as
    /// its token's session.
    func answerMCP(_ client: Int32, _ request: Request, session: String? = nil) {
        var request = request
        let name = Self.serverName(request.path)
        guard let endpoint = endpoints().first(where: { $0.name == name }) else {
            guard let server = inProcess[name] else { return Self.reply(client, "404 Not Found", "No MCP server \(name).") }
            // Its withheld tools kept from the sessions as an upstream's are: a call refused, the listing without them.
            let withheld = inProcessWithheld[name] ?? []
            var listing = false
            if !withheld.isEmpty {
                switch Self.checked(request, withheld: withheld) {
                case .refused(let error): return Self.send(client, Self.jsonAnswer(error))
                case .passed(let body, let lists):
                    request.body = body
                    listing = lists
                }
            }
            let answer = Self.answered(request, by: server)
            return Self.send(client, listing ? Self.withoutTools(withheld, in: answer) : answer)
        }
        guard let url = URLComponents(string: endpoint.url), url.scheme == "http", let host = url.host else {
            return Self.reply(client, "502 Bad Gateway", "\(endpoint.url) is not a plain HTTP address.")
        }
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
        let upstream = agent_proxy_connect_tcp(host, UInt16(port))
        guard upstream >= 0 else { return Self.reply(client, "502 Bad Gateway", "\(endpoint.url) doesn't answer.") }
        defer { close(upstream) }
        let path = (url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath) + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
        var head = "\(request.method) \(path) HTTP/1.1\r\n"
        for header in forwarded(request, to: endpoint, host: "\(host):\(port)", session: session) {
            // No line break in a header: it would be another header, or another request.
            guard !(header.name + header.value).contains(where: { $0 == "\r" || $0 == "\n" }) else {
                return Self.reply(client, "400 Bad Request", "A header with a line break.")
            }
            head += "\(header.name): \(header.value)\r\n"
        }
        Self.send(upstream, Data((head + "\r\n").utf8) + request.body)
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        var held = Data()
        while true {
            let count = buffer.withUnsafeMutableBytes { Foundation.read(upstream, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            if listing { held.append(contentsOf: buffer[0..<count]) } else { Self.send(client, Data(buffer[0..<count])) }
        }
        if listing { Self.send(client, Self.withoutTools(withheld, in: held)) }
    }

    /// A call answered by a server of this process's, waited for on this call's own thread (never a thread of Swift's
    /// pool): its whole HTTP answer. The sessions' token stops here, as it does before an upstream.
    static func answered(_ request: Request, by server: any InProcessMCP) -> Data {
        var headers: [String: String] = [:]
        for header in request.headers where header.name.lowercased() != tokenHeader.lowercased() {
            headers[header.name] = headers[header.name].map { $0 + ", " + header.value } ?? header.value
        }
        let method = request.method, body = request.body
        let answer = Locked<InProcessMCPAnswer?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task {
            let answered = await server.answer(method: method, headers: headers, body: body)
            answer.withLock { $0 = answered }
            done.signal()
        }
        done.wait()
        return (answer.withLock { $0 } ?? InProcessMCPAnswer(status: 500)).serialized
    }

    /// A request to an endpoint that withholds tools, checked.
    enum Checked: Equatable {
        /// Its body as it goes on, and whether it asks for the tools.
        case passed(Data, listsTools: Bool)
        /// The JSON-RPC error to answer with.
        case refused(Data)
    }

    /// A request to an endpoint that withholds tools, failing closed: a POST's body must be a JSON-RPC message or a
    /// batch of them (else -32600), and a `tools/call` must name, as a plain string, a tool not withheld (else
    /// -32601). What passes goes on as read here, written again, so the endpoint reads only what was checked. Another
    /// method (an MCP session's GET or DELETE) passes only with no body.
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
                return .refused(error(id: message["id"], -32601, "This tool is kept from Visor's sessions."))
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

    /// An endpoint's whole HTTP answer to `tools/list`, without the tools withheld: its body (de-chunked if it came
    /// so) rewritten, as JSON or as an SSE stream's `data:` lines, its length set again. An answer that isn't one of
    /// those (an error, one that can't be read) as it came: a withheld tool's call is refused all the same.
    static func withoutTools(_ withheld: Set<String>, in answer: Data) -> Data {
        let blank = Data("\r\n\r\n".utf8)
        guard let end = answer.range(of: blank) else { return answer }
        let head = String(decoding: answer[..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let headers = lines.dropFirst()
        func header(_ name: String) -> String? {
            headers.first { $0.lowercased().hasPrefix(name + ":") }.map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
        }
        var body = Data(answer[end.upperBound...])
        if let coding = header("transfer-encoding") {
            guard coding.lowercased() == "chunked", let whole = dechunked(body) else { return answer }
            body = whole
        }
        let type = header("content-type")?.lowercased() ?? ""
        let rewritten: Data?
        if type.hasPrefix("application/json") {
            rewritten = withoutTools(withheld, inMessage: body)
        } else if type.hasPrefix("text/event-stream") {
            // Each event's `data:` line a JSON-RPC message (MCP's streamable HTTP): the listing one rewritten.
            var changed = false
            let events = String(decoding: body, as: UTF8.self).components(separatedBy: "\n").map { line -> String in
                guard line.hasPrefix("data:") else { return line }
                let json = line.dropFirst(5).drop { $0 == " " }
                guard let message = withoutTools(withheld, inMessage: Data(json.utf8)) else { return line }
                changed = true
                return "data: " + String(decoding: message, as: UTF8.self)
            }
            rewritten = changed ? Data(events.joined(separator: "\n").utf8) : nil
        } else {
            rewritten = nil
        }
        guard let rewritten else { return answer }
        var kept = [lines[0]] + headers.filter {
            let name = $0.lowercased()
            return !name.hasPrefix("content-length:") && !name.hasPrefix("transfer-encoding:")
        }
        kept.append("Content-Length: \(rewritten.count)")
        return Data((kept.joined(separator: "\r\n") + "\r\n\r\n").utf8) + rewritten
    }

    /// A `tools/list` result's message without the tools withheld; nil for any other message.
    static func withoutTools(_ withheld: Set<String>, inMessage body: Data) -> Data? {
        guard var message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              var result = message["result"] as? [String: Any], let tools = result["tools"] as? [[String: Any]] else { return nil }
        result["tools"] = tools.filter { ($0["name"] as? String).map(withheld.contains) != true }
        message["result"] = result
        return try? JSONSerialization.data(withJSONObject: message)
    }

    /// A chunked body put together; nil if it isn't whole (cut short, a size that isn't hex).
    static func dechunked(_ body: Data) -> Data? {
        let bytes = [UInt8](body)
        var whole = Data()
        var at = 0
        while true {
            guard let lineEnd = (at..<max(at, bytes.count - 1)).first(where: { bytes[$0] == 13 && bytes[$0 + 1] == 10 }) else { return nil }
            let sizeText = String(decoding: bytes[at..<lineEnd], as: UTF8.self).split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else { return nil }
            at = lineEnd + 2
            if size == 0 { return whole }
            guard at + size + 2 <= bytes.count else { return nil }
            whole.append(contentsOf: bytes[at..<at + size])
            at += size + 2
        }
    }
}
