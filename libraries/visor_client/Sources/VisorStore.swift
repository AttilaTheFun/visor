// The saved agent servers and their live connections. Records persist
// through the host's settings service (UserDefaults on Apple, localStorage
// on the web), each secret apart from them (the keychain on Apple);
// connections are made on launch.
//
// A server is added through its provider's own sign-in. For a Mac that is
// one step: its connection code (pasted, or a scanned QR code's
// `visor://connect?code=` link) carries its name, address and password.
// Adding one adds this device to its network: the server tells of the
// other computers it knows, each is added here with every path to it
// (its own addresses, and through any server here that reaches it), and
// the servers this device holds are introduced to one another, so their
// agents reach each other's sessions with nothing more to do.

import MessageCache
import Observation
import SwiftUI
import VisorProtocol
import VisorServices

@MainActor
@Observable
public final class VisorStore {
    public private(set) var servers: [AgentServerConnection] = []
    /// The add sheet is open. Held here because the Mac opens it from its
    /// menu bar, which is a scene away from the view.
    public var addingServer = false
    /// A session a notification the user opened is about, for the view to
    /// open; cleared once it has.
    public var opening: NotificationTarget?
    /// Bumped when a server's record changes, so views of the store refresh.
    private var revision = 0
    /// Under the key an earlier build saved its computers.
    private let key = "hosts"
    /// Whether the app's account (`VisorAccounts.current`) is signed in;
    /// false where there is none. While it is not, a view shows the
    /// account's sign-in in place of the computers.
    public internal(set) var accountSignedIn = false

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
        // The computers are kept with the secrets (the keychain on Apple):
        // they survive the app being deleted and installed again.
        let saved = VisorHost.settings?.kept(key: key) ?? ""
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
        startAccount()
        listenForNotifications()
        AgentServerAuthenticators.whenSignedIn { [weak self] id, serving in self?.signedIn(id, serving: serving) }
        // Where the device is decides which path to each computer fits:
        // a change is acted on once the networks have settled. The path
        // monitor speaks several times as it starts and as an interface
        // comes up, and each word acted on restarted every sign-in.
        VisorHost.network?.onChange = { [weak self] in self?.networksChanged() }
    }

    /// The pending reaction to the networks changing.
    private var networksSettle: Task<Void, Never>?
    /// How long the networks must stay as they are before it is acted on.
    static let networkSettling: UInt64 = 400_000_000

    func networksChanged() {
        networksSettle?.cancel()
        networksSettle = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.networkSettling)
            guard !Task.isCancelled, let self else { return }
            self.servers.forEach { $0.networkChanged() }
        }
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

    /// Adds a server and connects to it — or, for one held already (the
    /// same address, or the same server id), takes the new record in: the
    /// password, the name, the paths, and the address, which the new
    /// record puts first (an SSH connection code for a computer held
    /// over HTTP makes SSH the way in).
    /// `authenticationGiven`: whether `record.authentication` was chosen
    /// (a code that said, the form); false, or none named (a code that
    /// did not say), leaves a held computer's own, and a new one signs in
    /// by password.
    @discardableResult
    public func add(_ record: AgentServerRecord, authenticationGiven: Bool = true) -> AgentServerConnection {
        let authenticationGiven = authenticationGiven && !record.authentication.isEmpty
        var record = record
        if let existing = held(record) {
            let isolated = existing.isolated
            existing.update { current in
                if !record.name.isEmpty, !current.renamed { current.name = record.name }
                if current.serverID.isEmpty { current.serverID = record.serverID }
                // Standing alone: its address and its way of signing in
                // stand; the password is taken if it signs in by one.
                if isolated {
                    if current.authentication == PasswordAuthenticator.name, !record.secret.isEmpty { current.secret = record.secret }
                    return
                }
                current.secret = record.secret
                let before = current.address
                current.address = record.address
                current.learnPaths(record.paths + [before])
                // A code that does not say how to sign in leaves it as it is.
                if authenticationGiven { current.authentication = record.authentication }
            }
            existing.connect()
            save()
            return existing
        }
        if record.authentication.isEmpty { record.authentication = PasswordAuthenticator.name }
        let server = AgentServerConnection(record: record)
        servers.append(server)
        observe(server)
        server.connect()
        save()
        return server
    }

    /// What the last `visor://authorize` link did: which computers took
    /// the key, for the app to show; cleared once shown.
    public var notice: String?

    /// A connection code or a `visor://connect` link: the Mac it names is
    /// added (or its password updated) and connected. A
    /// `visor://authorize` link (another device's SSH key, scanned): the
    /// key is handed to every computer connected here, so that device
    /// comes in over SSH. Nil when the text is neither, or for a key.
    @discardableResult
    public func open(_ text: String) -> AgentServerConnection? {
        if let link = SSHKeyLink(parsing: text) {
            authorize(link.key)
            return nil
        }
        guard let code = ConnectionCode(parsing: text) else { return nil }
        addingServer = false
        return add(AgentServerRecord(code: code))
    }

    /// Hands a device's SSH key to every computer connected here.
    public func authorize(_ key: String) {
        addingServer = false
        // Not to a server that stands alone: nothing goes to it from here.
        let connected = servers.filter { $0.state == .connected && !$0.isolated }
        guard !connected.isEmpty else {
            notice = "No computer is connected to hand the key to."
            return
        }
        Task { @MainActor in
            var took: [String] = []
            var refused: [String] = []
            for server in connected {
                do {
                    try await server.server.authorizeSSHKey(key)
                    took.append(server.record.name.isEmpty ? server.record.address : server.record.name)
                } catch {
                    refused.append(server.record.name.isEmpty ? server.record.address : server.record.name)
                }
            }
            var lines: [String] = []
            if !took.isEmpty { lines.append("The device's key is authorized on " + took.joined(separator: ", ") + ": it can connect over SSH now.") }
            if !refused.isEmpty { lines.append("Not on " + refused.joined(separator: ", ") + ".") }
            notice = lines.joined(separator: " ")
        }
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

    /// The server held here that a record is of: the same kind, at the
    /// same address or with the same server id.
    private func held(_ record: AgentServerRecord) -> AgentServerConnection? {
        servers.first { $0.record.provider == record.provider
            && ($0.record.address == record.address || (!record.serverID.isEmpty && $0.record.serverID == record.serverID)) }
    }

    /// An authenticator signed in for many records: those of them that
    /// were waiting for it connect again.
    private func signedIn(_ authenticatorID: String, serving: (AgentServerRecord) -> Bool) {
        for server in servers where server.record.authentication == authenticatorID && serving(server.record) {
            switch server.state {
            case .needsAuthentication, .failed: server.connect()
            default: break
            }
        }
    }

    /// A server connected and said who it is: the other servers its way of
    /// signing in reaches are added; another record of the same computer
    /// is folded into it, the computers it knows are taken in, and it and
    /// the others here are introduced to one another.
    private func joined(_ server: AgentServerConnection) async {
        guard !VisorFixture.active else { return }
        await discover(from: server)
        // A server that stands alone shares nothing and is told nothing.
        guard !server.isolated else { return }
        fold(server)
        if let peers = try? await server.peers() {
            for peer in peers { take(peer, from: server) }
        }
        let others = servers.filter { $0 !== server && !$0.isolated }.compactMap(\.asPeer)
        if !others.isEmpty { try? await server.introduce(others) }
        if let me = server.asPeer {
            for other in servers where other !== server && other.state == .connected && !other.isolated { try? await other.introduce([me]) }
        }
    }

    /// The servers behind the same front as this one, as its
    /// authenticator finds them: those not held here are added.
    private func discover(from server: AgentServerConnection) async {
        let found = (try? await AgentServerAuthenticators.authenticator(for: server.record).discover(from: server.record)) ?? []
        for record in found where held(record) == nil { add(record) }
    }

    /// Two records of one computer (added by two paths before either had
    /// said its id): the other's paths are kept here, the other goes.
    private func fold(_ server: AgentServerConnection) {
        let id = server.record.serverID
        guard !id.isEmpty else { return }
        for other in servers where other !== server && other.record.serverID == id {
            server.update { $0.learnPaths(other.record.allPaths) }
            remove(other)
        }
    }

    /// What a server says of another computer: more paths (and the
    /// password, if none is kept) for one held here, or a new one, added
    /// and connected — by one of its own addresses, or through the server
    /// that told of it.
    func take(_ peer: Peer, from teller: AgentServerConnection) {
        guard !teller.isolated, let first = peer.addresses.first, peer.id.isEmpty || peer.id != teller.record.serverID else { return }
        if let known = servers.first(where: { $0.record.isSame(as: peer) }) {
            known.learn(peer)
            return
        }
        let record = AgentServerRecord(name: peer.name, address: first, secret: peer.password, serverID: peer.id, paths: Array(peer.addresses.dropFirst()))
        let added = AgentServerConnection(record: record)
        servers.append(added)
        observe(added)
        added.connect()
        save()
    }

    /// The paths to a server through the others connected here: each
    /// carries requests to a computer it knows (`/peer/<id>` under it).
    func relayPaths(to target: AgentServerConnection) -> [String] {
        let id = target.record.serverID
        guard !id.isEmpty, !target.isolated else { return [] }
        return servers.filter { $0 !== target && $0.state == .connected && $0.record.serverID != id && !$0.isolated }
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
        server.relayPaths = { [weak self, weak server] in
            guard let self, let server else { return [] }
            return self.relayPaths(to: server)
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
        VisorHost.settings?.setKept(key: key, value: JSONValue.array(records).encoded())
    }
}
