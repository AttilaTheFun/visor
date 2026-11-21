// The MCP servers this server passes on to its sessions' agents
// (MCPEndpoint): a session's tools from each it has, named
// `<endpoint>__<tool>`, and its calls passed on with its own headers. Visor's
// MCP script (VisorMCPScript) asks for both over the agent's WebSocket; an
// agent never sees an endpoint's address or its secret headers.
//
// A session's tools are its endpoints' last good lists (MCPListing): every
// endpoint asked at once, each within `listTimeout`; one that fails or is
// slow keeps its last good list (a call to it fails with why) and is asked
// again after a wait that doubles, up to `listRetryLimit`, so a down
// endpoint costs a list nothing. Only once it has failed for `forgetAfter`
// are its tools left out (the agent told once), and back when it answers
// again (told once more). Before 0.65 each was asked in turn with a minute
// to answer, and one that failed was left out of that list at once.

import Foundation
import VisorProtocol

@MainActor
final class MCPProxy {
    /// Each session's conversation with each endpoint, by endpoint and session.
    private var connections: [String: MCPConnection] = [:]
    /// The most pages of tools asked of one endpoint.
    nonisolated static let pages = 10
    /// How long a call may run (a test suite, a lease that waits).
    nonisolated static let callTimeout: Double = 900
    /// How long an endpoint's list may take, and its `initialize` (a test's
    /// is shorter).
    var listTimeout: Double = 5
    /// The longest wait before an endpoint that failed is asked again (2 s
    /// after the first failure, doubled after each).
    nonisolated static let listRetryLimit: Double = 60
    /// How long an endpoint may fail before its tools are left out.
    nonisolated static let forgetAfter: Double = 15 * 60
    /// Each session's last good list from each endpoint, by endpoint and
    /// session, as `connections`.
    private var listings: [String: MCPListing] = [:]
    /// The time now: a test's own.
    var now: () -> Date = Date.init

    /// The tools of the endpoints a session has, each renamed under its
    /// endpoint, in the endpoints' order: each endpoint's as it lists them
    /// now, or its last good list where it doesn't (none once it has failed
    /// for `forgetAfter`, or if it never answered). An endpoint waiting out
    /// its retry isn't asked.
    func tools(of endpoints: [MCPEndpoint], session: String, title: String, repository: String, secrets: any SecretStore) async -> [JSONValue] {
        let asked = now()
        // A task of the main actor's for each endpoint asked, begun before
        // any is waited on: they wait on their endpoints together.
        var asking: [(index: Int, list: Task<[JSONValue]?, Never>)] = []
        for (index, endpoint) in endpoints.enumerated() {
            let key = endpoint.name + "\u{0}" + session
            if let listing = listings[key], listing.url == endpoint.url, asked < listing.retryAt { continue }
            let connection = connection(endpoint, session: session, title: title, repository: repository, secrets: secrets)
            let timeout = listTimeout
            asking.append((index, Task { await Self.list(endpoint, on: connection, timeout: timeout) }))
        }
        var fresh: [Int: [JSONValue]?] = [:]
        for (index, list) in asking { fresh.updateValue(await list.value, forKey: index) }
        let answered = now()
        var listed: [JSONValue] = []
        for (index, endpoint) in endpoints.enumerated() {
            let key = endpoint.name + "\u{0}" + session
            var listing = listings[key].flatMap { $0.url == endpoint.url ? $0 : nil } ?? MCPListing(url: endpoint.url)
            if let tools = fresh[index] {
                if let tools { listing.answered(tools) } else { listing.failed(at: answered) }
                listings[key] = listing
            }
            listed += listing.tools(at: answered) ?? []
        }
        return listed
    }

    /// An endpoint's tools as it lists them now, each request within
    /// `timeout`; nil when it doesn't.
    private static func list(_ endpoint: MCPEndpoint, on connection: MCPConnection, timeout: Double) async -> [JSONValue]? {
        var listed: [JSONValue] = []
        var cursor: String?
        for _ in 0..<pages {
            let params: JSONValue = cursor.map { .object(["cursor": .string($0)]) } ?? .object([:])
            guard let page = try? await connection.request("tools/list", params, timeout: timeout) else { return nil }
            for tool in page["tools"].array ?? [] {
                guard var fields = tool.object, let name = tool["name"].string else { continue }
                fields["name"] = .string(endpoint.name + "__" + name)
                listed.append(.object(fields))
            }
            cursor = page["nextCursor"].string
            if cursor == nil { break }
        }
        return listed
    }

    /// A call of `tool` (`<endpoint>__<tool>`) passed on to its endpoint,
    /// answered with the endpoint's result as it gave it.
    func call(_ tool: String, arguments: JSONValue, endpoints: [MCPEndpoint], session: String, title: String, repository: String,
              secrets: any SecretStore) async throws -> JSONValue {
        guard let split = tool.range(of: "__") else { throw MCPProxyError.noEndpoint(tool) }
        let name = String(tool[..<split.lowerBound])
        guard let endpoint = endpoints.first(where: { $0.name == name }) else { throw MCPProxyError.noEndpoint(name) }
        let connection = connection(endpoint, session: session, title: title, repository: repository, secrets: secrets)
        return try await connection.request("tools/call", .object(["name": .string(String(tool[split.upperBound...])), "arguments": arguments]),
                                            timeout: Self.callTimeout)
    }

    /// A session's connection to an endpoint, its headers as they are now;
    /// a new one when the endpoint moved.
    private func connection(_ endpoint: MCPEndpoint, session: String, title: String, repository: String,
                            secrets: any SecretStore) -> MCPConnection {
        let key = endpoint.name + "\u{0}" + session
        let headers = endpoint.filledHeaders(session: session, title: title, repository: repository, secrets: secrets)
        if let known = connections[key], known.url == endpoint.url {
            known.headers = headers
            return known
        }
        let made = MCPConnection(url: endpoint.url, headers: headers)
        connections[key] = made
        return made
    }

    /// A session's connections let go: it ended.
    func forget(session: String) {
        connections = connections.filter { !$0.key.hasSuffix("\u{0}" + session) }
        listings = listings.filter { !$0.key.hasSuffix("\u{0}" + session) }
    }
}
