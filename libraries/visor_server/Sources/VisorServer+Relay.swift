// Relaying for a peer: a client that reaches this server but not the
// peer (a phone on the LAN, the peer on the VPN) reads the peer's API
// here, under `/peer/<id>/…`, and this server carries each request
// there — with the peer's password, down a path it has — and the answer
// back. HTTP only: a WebSocket upgrade there is refused, so the client
// follows the peer by polling, as behind any front without WebSockets.
// A request names the servers it has passed through (`X-Visor-Relay`),
// so none carries it twice and no chain runs long.

import Foundation
import VisorProtocol

extension VisorServer {
    /// How many servers a relayed request may pass through.
    static let longestRelay = 3
    /// How long a relayed request may take: a held poll, and the road.
    static let relayTimeout: Double = pollHold + 20

    /// A path under `/peer/<id>`: the id, and the rest of the path (with
    /// its query) as the peer reads it.
    static func relayTarget(_ path: String) -> (id: String, rest: String)? {
        guard let range = path.range(of: "/peer/") else { return nil }
        let after = path[range.upperBound...]
        let id = String(after.prefix { $0 != "/" && $0 != "?" })
        guard !id.isEmpty else { return nil }
        var rest = String(after.dropFirst(id.count))
        if rest.isEmpty || rest.hasPrefix("?") { rest = "/" + rest }
        return (id, rest)
    }

    /// Carries a request to the peer and its answer back.
    func relay(_ target: (id: String, rest: String), _ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        guard let peer = peers.first(where: { $0.id == target.id }) else {
            return respond(HTTPResponse(404, Envelope.error("No such computer on the network").encoded()))
        }
        let passed = (request.headers["x-visor-relay"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !passed.contains(id), passed.count < Self.longestRelay else {
            return respond(HTTPResponse(508, Envelope.error("The request has been relayed too far").encoded()))
        }
        var headers = ["Authorization": "Bearer \(peer.password)", "X-Visor-Relay": (passed + [id]).joined(separator: ",")]
        if let type = request.headers["content-type"] { headers["Content-Type"] = type }
        let candidates = paths(to: peer).filter { candidate in !passed.contains { candidate.contains("/peer/" + $0) } }
        Task { @MainActor in
            for base in candidates {
                let outgoing = OutgoingRequest(url: base + target.rest, method: request.method, headers: headers,
                                               body: Data(request.body.utf8), timeout: Self.relayTimeout)
                guard let answer = try? await ServerPlatform.current.fetching.fetch(outgoing) else { continue }
                // A path that answers at all is the path; what it answered
                // is the peer's own answer, whatever the status.
                self.workingPaths[peer.id] = base
                return respond(HTTPResponse(answer.status, String(decoding: answer.body, as: UTF8.self)))
            }
            respond(HTTPResponse(502, Envelope.error("\(peer.name) is not reachable from here").encoded()))
        }
    }
}
