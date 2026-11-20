// What Visor.app asks of the server agent when it is its client, over the
// server's trusted socket file (~/.visor/server.sock, this user's alone, so
// no password): the few things the app did to its own server in its
// process, until the app is wholly the server's client (0b).

import Foundation
import VisorProtocol
import VisorServerCLI
import VisorServerPOSIX

@MainActor
enum MacServerCalls {
    /// The answer's envelope; nil when there was none, or another status.
    static func call(_ method: String, _ path: String, body: String = "") async -> Envelope? {
        let call = LocalServerCall(method: method, path: path, body: body)
        guard let answer = try? await call.send(connect: { await POSIXUnixSocket.connect($0) }), answer.status == 200 else { return nil }
        return Envelope.decode(answer.body)
    }

    /// The server's version, as `/api/hello` says it.
    static func version() async -> String? {
        await call("GET", "/api/hello")?.version
    }

    /// Whether any session is mid-turn.
    static func busy() async -> Bool {
        (await call("GET", "/api/sessions")?.sessions ?? []).contains { $0.busy }
    }

    /// `POST /api/restart`, with the bundle to install (nil: a plain
    /// restart). What went wrong, or nil.
    static func restart(installing path: String?) async -> String? {
        var body: [String: JSONValue] = [:]
        if let path { body["path"] = .string(path) }
        let call = LocalServerCall(method: "POST", path: "/api/restart", body: JSONValue.object(body).encoded())
        do {
            let answer = try await call.send(connect: { await POSIXUnixSocket.connect($0) })
            guard answer.status == 200 else { return Envelope.decode(answer.body)?.error ?? "the server answered \(answer.status)" }
            return nil
        } catch {
            return "\(error)"
        }
    }
}
