// The saved agent servers and their live connections. Records persist
// through the host's settings service (UserDefaults on Apple, localStorage
// on the web), each secret apart from them (the keychain on Apple);
// connections are made on launch.
//
// A server is added through its provider's own sign-in. For a Mac that is
// one step: its connection code (pasted, or a scanned QR code's
// `visor://connect?code=` link) carries its name, address and password.
// Adding one adds this device to its network: the server tells of the
// other computers it knows, each is added here with every road to it
// (its own addresses, and through any server here that reaches it), and
// the servers this device holds are introduced to one another, so their
// agents reach each other's sessions with nothing more to do.

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

    /// A server connected and said who it is: another record of the same
    /// computer is folded into it, the computers it knows are taken in,
    /// and it and the others here are introduced to one another.
    private func joined(_ server: AgentServerConnection) async {
        guard !VisorFixture.active else { return }
        fold(server)
        if let peers = try? await server.peers() {
            for peer in peers { take(peer, from: server) }
        }
        let others = servers.filter { $0 !== server }.compactMap(\.asPeer)
        if !others.isEmpty { try? await server.introduce(others) }
        if let me = server.asPeer {
            for other in servers where other !== server && other.state == .connected { try? await other.introduce([me]) }
        }
    }

    /// Two records of one computer (added by two roads before either had
    /// said its id): the other's roads are kept here, the other goes.
    private func fold(_ server: AgentServerConnection) {
        let id = server.record.serverID
        guard !id.isEmpty else { return }
        for other in servers where other !== server && other.record.serverID == id {
            server.update { $0.learnRoads(other.record.allRoads) }
            remove(other)
        }
    }

    /// What a server says of another computer: more roads (and the
    /// password, if none is kept) for one held here, or a new one, added
    /// and connected — by one of its own addresses, or through the server
    /// that told of it.
    func take(_ peer: Peer, from teller: AgentServerConnection) {
        guard let first = peer.addresses.first, peer.id.isEmpty || peer.id != teller.record.serverID else { return }
        if let known = servers.first(where: { $0.record.isSame(as: peer) }) {
            known.learn(peer)
            return
        }
        let record = AgentServerRecord(name: peer.name, address: first, secret: peer.password, serverID: peer.id, roads: Array(peer.addresses.dropFirst()))
        let added = AgentServerConnection(record: record)
        servers.append(added)
        observe(added)
        added.connect()
        save()
    }

    /// The roads to a server through the others connected here: each
    /// carries requests to a computer it knows (`/peer/<id>` under it).
    func relayRoads(to target: AgentServerConnection) -> [String] {
        let id = target.record.serverID
        guard !id.isEmpty else { return [] }
        return servers.filter { $0 !== target && $0.state == .connected && $0.record.serverID != id }
            .compactMap { other in other.server.reachedAt.map { $0 + "/peer/" + id } }
    }

    /// The app came back to the front: every server is tried or checked
    /// at once (`AgentServerConnection.resume`). After time in the
    /// background on a host whose sockets do not outlive it (a phone),
    /// each channel is opened afresh without being asked first.
    public func resume(afterBackground: Bool = false) {
        guard !VisorFixture.active else { return }
        let fresh = afterBackground && (VisorHost.socket?.dropsInBackground ?? false)
        ConnectionLog.shared.note("app", "in front" + (afterBackground ? ", back from the background" : "")
                                  + (fresh ? ": every channel is opened afresh" : ""))
        // Requests must not ride connections that died while the app was
        // away: the host starts over with new ones.
        if fresh { VisorHost.http?.reset() }
        servers.forEach { $0.resume(fresh: fresh) }
    }

    /// The app left the front for the background: each server's retry
    /// schedule starts over, and the log is kept for the next run.
    public func suspend() {
        guard !VisorFixture.active else { return }
        ConnectionLog.shared.note("app", "in the background")
        servers.forEach { $0.suspend() }
        ConnectionLog.shared.keep()
    }

    /// The app is in front but not the one being used (the app switcher,
    /// a system sheet over it): only said, for the log.
    public func noteInactive() {
        guard !VisorFixture.active else { return }
        ConnectionLog.shared.note("app", "inactive")
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
        server.relayRoads = { [weak self, weak server] in
            guard let self, let server else { return [] }
            return self.relayRoads(to: server)
        }
        server.onConnected = { [weak self, weak server] in
            guard let self, let server else { return }
            Task { await self.joined(server) }
        }
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
