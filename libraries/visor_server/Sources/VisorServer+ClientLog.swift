// What the log says of clients: who signed in, who was refused, who left
// and after how long. An agent's one-request connections (the Visor MCP
// server's calls, the permission shim's) are left out: they come and go
// every few seconds and said nothing ("a client connected/left", 9 Nov 2026,
// when the MacBook's client dropped and the log couldn't say which it was).

import Foundation

extension VisorServer {
    /// The clients signed in now.
    var signedIn: Int { connections.values.filter(\.authenticated).count }

    /// "Logan’s MacBook Pro (client 1a2b3c4d)", as far as the client's
    /// login and its reports say; "a client" before it has said.
    func describe(_ client: ClientConnection) -> String {
        if client.trusted && client.clientID == nil { return "a client on the socket file" }
        guard let id = client.clientID, !id.isEmpty else { return "a client that gave no id" }
        let name = directory[id]?.report.clientName ?? ""
        let short = "client \(id.prefix(8))"
        return name.isEmpty ? short : "\(name) (\(short))"
    }

    /// A connection gone: a client that signed in, or one that closed
    /// before it did (a proxy, TLS or a client that gave up).
    func logLeaving(_ client: ClientConnection) {
        guard !client.agent else { return }
        let stayed = Self.duration(Date().timeIntervalSince(client.since))
        if client.authenticated {
            Self.log("\(describe(client)) left after \(stayed) (\(signedIn) signed in now)")
        } else if client.clientID == nil {
            Self.log("a connection closed after \(stayed) without signing in")
        }
    }
}
