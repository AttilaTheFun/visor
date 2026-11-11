// `GET /api/health`: whether the server answers, asked without credentials
// by whatever keeps it running (Shireworks' primary container,
// docs/server-proxy.md). It is answered from the server's own loop, as
// every request is, so a server that hangs doesn't answer, as one that has
// ended doesn't.

import Foundation
import VisorProtocol

extension VisorServer {
    /// Whether a request is the health check, which needs no credentials.
    static func isHealthCheck(_ request: HTTPRequest) -> Bool {
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        return request.method == "GET" && apiPath(path) == "/health"
    }

    /// `{"ok": true, "version": "…"}`.
    func restHealth() -> HTTPResponse {
        let body: JSONValue = .object(["ok": .bool(true), "version": .string(Self.version)])
        return HTTPResponse(200, body.encoded())
    }
}
