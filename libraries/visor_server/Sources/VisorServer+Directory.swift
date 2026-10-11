// What the clients connected to this server say they are connected to:
// each client's last report (`POST /api/relay`), kept by its id. From
// these the agents here learn the other servers and their sessions, and
// a message for one of them waits for a client that reported it.
// Nothing is kept on disk: the clients report again within moments of a
// restart.

import Foundation
import VisorProtocol

extension VisorServer {
    /// How long a client's report stands after it last reported: one that
    /// is open reports every few seconds, so one silent this long has gone.
    static let reportKept: TimeInterval = 10 * 60

    /// A client's report, in place of its last.
    func takeReport(_ report: DirectoryReport, now: Date = Date()) {
        guard !report.client.isEmpty else { return }
        directory[report.client] = ClientDirectoryEntry(report: report, at: now)
        dropOldReports(now: now)
    }

    func dropOldReports(now: Date = Date()) {
        directory = directory.filter { now.timeIntervalSince($0.value.at) < Self.reportKept }
    }

    /// The other servers the clients report, each as last reported (by
    /// whichever client reported it last), by name.
    func reportedServers(now: Date = Date()) -> [(server: DirectoryServer, by: String, at: Date)] {
        dropOldReports(now: now)
        var latest: [String: (server: DirectoryServer, by: String, at: Date)] = [:]
        for entry in directory.values {
            let by = entry.report.clientName.isEmpty ? entry.report.client : entry.report.clientName
            for server in entry.report.servers where server.id != id && !server.id.isEmpty {
                if let kept = latest[server.id], kept.at >= entry.at { continue }
                latest[server.id] = (server, by, entry.at)
            }
        }
        return latest.values.sorted { ($0.server.name.lowercased(), $0.server.id) < ($1.server.name.lowercased(), $1.server.id) }
    }

    /// The reported servers an agent's word for one names: the one with
    /// that id, or else every one with that name (as written, or as a
    /// session id from before ids wrote it, `logans-mac-mini`).
    func reportedServers(matching key: String) -> [DirectoryServer] {
        let servers = reportedServers().map(\.server)
        if let byID = servers.first(where: { $0.id == key }) { return [byID] }
        return servers.filter { Self.sameName($0.name, key) }
    }

    /// The reported servers with a session of that id, with the session.
    func reportedSessions(withID session: String) -> [(server: DirectoryServer, session: DirectorySession)] {
        reportedServers().flatMap { reported in
            reported.server.sessions.filter { $0.id == session }.map { (reported.server, $0) }
        }
    }

    /// Whether a word an agent wrote names this server: its id, or its name.
    func isThisServer(_ key: String) -> Bool {
        key == id || Self.sameName(hostName, key)
    }

    /// Two names for a computer alike: the same but for case, or the same
    /// words joined by dashes.
    static func sameName(_ name: String, _ key: String) -> Bool {
        name.caseInsensitiveCompare(key) == .orderedSame || slug(name) == slug(key)
    }

    static func slug(_ name: String) -> String {
        name.lowercased().split { !($0.isLetter || $0.isNumber) || !$0.isASCII }.joined(separator: "-")
    }
}
