// The saved agent servers and their live connections. Records persist
// through the host's settings service (UserDefaults on Apple, localStorage
// on the web), each secret apart from them (the keychain on Apple);
// connections are made on launch.
//
// A server is added through its provider's own sign-in. For a Mac that is
// one step: its connection code (pasted, or a scanned QR code's
// `visor://connect?code=` link) carries its name, address and password.

import MessageCache
import SwiftUI
import VisorProtocol
import VisorServices

@MainActor
public final class VisorStore: ObservableObject {
    @Published public private(set) var servers: [AgentServerConnection] = []
    /// The add sheet is open. Held here because the Mac opens it from its
    /// menu bar, which is a scene away from the view.
    @Published public var addingServer = false
    /// A session a notification the user opened is about, for the view to
    /// open; cleared once it has.
    @Published public var opening: NotificationTarget?
    /// Bumped when a server's record changes, so views of the store refresh.
    @Published private var revision = 0
    /// Under the key an earlier build saved its computers.
    private let key = "hosts"

    public init() {
        // Screenshot tests: only the canned server, its rows in memory,
        // and nothing of the real ones read or written.
        if VisorFixture.active {
            AgentServerProviders.register(FixtureAgentServerProvider())
            MessageCache.storageProvider = { _ in MemoryStorage() }
            servers = [AgentServerConnection(record: VisorFixture.record)]
            for server in servers { observe(server); server.connect() }
            addingServer = VisorFixture.screen == "connect"
            return
        }
        let saved = VisorHost.settings?.get(key: key) ?? ""
        if !saved.isEmpty, let records = parseJSON(saved)?.array?.compactMap(AgentServerRecord.init(json:)) {
            var carried = false
            servers = records.map { record in
                var record = record
                if record.secret.isEmpty {
                    record.secret = VisorHost.settings?.secret(key: Self.secretKey(record.id)) ?? ""
                } else {
                    // Saved with its password, from before secrets: moved.
                    carried = true
                }
                return AgentServerConnection(record: record)
            }
            if carried { save() }
        }
        for server in servers { observe(server); server.connect() }
        listenForNotifications()
    }

    /// A push token arriving goes to every server; a notification the
    /// user opens names a session to open.
    private func listenForNotifications() {
        VisorNotificationHandler.shared.onToken = { [weak self] in
            Task { self?.servers.forEach { $0.registerForPush() } }
        }
        VisorNotificationHandler.shared.onOpen = { [weak self] target in
            Task { self?.opening = target }
        }
    }

    /// The session on screen, if any: a notification about it, with the app
    /// in front, is not shown over it.
    public func noteViewing(serverID: String?, sessionID: String?) {
        guard let serverID, let sessionID, let server = server(for: serverID) else {
            VisorNotificationHandler.shared.viewing = nil
            return
        }
        VisorNotificationHandler.shared.viewing = NotificationTarget(computer: server.record.address, session: sessionID)
    }

    /// The server a notification names, by the address it goes by.
    public func server(named computer: String) -> AgentServerConnection? {
        servers.first { $0.record.address == computer } ?? servers.first { $0.record.name == computer }
    }

    /// Adds (or updates, by provider and address) a server and connects to it.
    @discardableResult
    public func add(_ record: AgentServerRecord) -> AgentServerConnection {
        if let existing = servers.first(where: { $0.record.provider == record.provider && $0.record.address == record.address }) {
            existing.update { current in
                current.secret = record.secret
                if !record.name.isEmpty { current.name = record.name }
            }
            existing.connect()
            save()
            return existing
        }
        let server = AgentServerConnection(record: record)
        servers.append(server)
        observe(server)
        server.connect()
        save()
        return server
    }

    /// A connection code or a `visor://connect` link: the Mac it names is
    /// added (or its password updated) and connected. Nil when the text
    /// is neither.
    @discardableResult
    public func open(_ text: String) -> AgentServerConnection? {
        guard let code = ConnectionCode(parsing: text) else { return nil }
        addingServer = false
        return add(AgentServerRecord(name: code.name, address: code.host, secret: code.password))
    }

    public func remove(_ server: AgentServerConnection) {
        server.disconnect()
        servers.removeAll { $0 === server }
        VisorHost.settings?.setSecret(key: Self.secretKey(server.id), value: "")
        save()
    }

    /// Where a server's secret is kept, apart from its record (under the
    /// key an earlier build kept the password).
    static func secretKey(_ id: String) -> String { "password." + id }

    public func server(for id: String) -> AgentServerConnection? { servers.first { $0.id == id } }

    /// Links every connected server to one another, so the agents on each
    /// reach the sessions on the others: each gives its connection code,
    /// and each is handed the others'. Nil when all are linked; otherwise
    /// what went wrong, per server.
    public func linkServers() async -> String? {
        let connected = servers.filter { $0.state == .connected }
        guard connected.count > 1 else { return "Connect to two or more computers first." }
        var codes: [(server: AgentServerConnection, code: String)] = []
        var problems: [String] = []
        for server in connected {
            do { codes.append((server, try await server.connectionCode())) } catch { problems.append("\(server.record.name): \(Self.describe(error))") }
        }
        for (server, _) in codes {
            for (other, code) in codes where other !== server {
                do { try await server.link(code: code) } catch { problems.append("\(server.record.name) → \(other.record.name): \(Self.describe(error))") }
            }
        }
        return problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? AgentServerError {
            switch error {
            case .message(let message): return message
            case .unsupported: return "it cannot be linked"
            case .needsAuthentication: return "it needs signing in"
            }
        }
        if let status = VisorHost.http?.status(of: error) { return status == 404 ? "its Visor Server is too old to link" : "it answered \(status)" }
        return "not reachable"
    }

    /// The servers answering now: where a new session can go.
    public var connectedServers: [AgentServerConnection] { servers.filter { $0.state == .connected } }

    private func observe(_ server: AgentServerConnection) {
        server.onRecordChange = { [weak self] in
            guard let self else { return }
            self.revision += 1
            self.save()
        }
        server.onSessionsChange = { [weak self] in self?.publishWidget() }
    }

    /// The latest sessions on every server, for the home screen's widget:
    /// published when they change, as JSON the widget reads.
    private var published = ""
    func publishWidget() {
        // The canned server never reaches the real home screen.
        guard let widget = VisorHost.widget, !VisorFixture.active else { return }
        let json = WidgetSessions.json(servers.flatMap { server in
            server.sessions.map { WidgetSessions.Source(computer: server.record.name, address: server.record.address, info: $0) }
        })
        guard json != published else { return }
        published = json
        widget.publish(json)
    }

    private func save() {
        // The canned server is never saved over the real ones.
        guard !VisorFixture.active else { return }
        // The records without their secrets; each secret apart.
        let records = servers.map { server -> JSONValue in
            var record = server.record
            VisorHost.settings?.setSecret(key: Self.secretKey(record.id), value: record.secret)
            record.secret = ""
            return record.json
        }
        VisorHost.settings?.set(key: key, value: JSONValue.array(records).encoded())
    }
}
