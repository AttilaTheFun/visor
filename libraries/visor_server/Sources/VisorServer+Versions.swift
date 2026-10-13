// Which builds are installed and running: this server says its own at a
// client's sign-in (`hello`'s `version`); each client says its own in its
// reports, with the version of every server it is connected to. So each
// server knows its clients' builds and, through them, the other servers'
// — told to its agents with the sessions (list_sessions) and to anything
// that asks (`GET /api/versions`).

import Foundation
import VisorProtocol

extension VisorServer {
    /// This server's version and build ("0.31 (8)"); empty where the binary
    /// does not say.
    static var version: String { ServerPlatform.current.host.version }

    /// The clients that reported here lately, newest report first: name,
    /// system, build, and when.
    func reportedClients(now: Date = Date()) -> [(name: String, platform: String, version: String, at: Date)] {
        dropOldReports(now: now)
        return directory.values.sorted { $0.at > $1.at }.map { entry in
            let report = entry.report
            return (report.clientName.isEmpty ? report.client : report.clientName, report.clientPlatform ?? "", report.clientVersion ?? "", entry.at)
        }
    }

    /// "Visor 0.31 (8) on iOS", as far as a client said.
    static func describe(app: String, version: String, platform: String) -> String {
        [app, version.isEmpty ? "(version not reported)" : version, platform.isEmpty ? "" : "on \(platform)"]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The builds as known here: this server's, its clients', and the other
    /// servers' as their clients reported them.
    func restVersions(_ call: RESTCall) -> HTTPResponse {
        let now = Date()
        let clients: [JSONValue] = reportedClients(now: now).map { client in
            .object(["name": .string(client.name), "platform": .string(client.platform), "version": .string(client.version),
                     "reported": .number(client.at.timeIntervalSince1970)])
        }
        let servers: [JSONValue] = reportedServers(now: now).map { reported in
            .object(["id": .string(reported.server.id), "name": .string(reported.server.name), "version": .string(reported.server.version ?? ""),
                     "reportedBy": .string(reported.by), "reported": .number(reported.at.timeIntervalSince1970)])
        }
        let this: JSONValue = .object(["id": .string(id), "name": .string(hostName), "version": .string(Self.version)])
        return .json(JSONValue.object(["server": this, "clients": .array(clients), "servers": .array(servers)]).encoded())
    }
}
