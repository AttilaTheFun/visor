// The saved computers and their live connections. Configs persist through
// the host's settings service (UserDefaults on Apple, localStorage on the
// web), each password apart from them as a secret (the keychain on Apple);
// connections are made on launch.
//
// A computer is added in one step: its connection code (pasted, or a
// scanned QR code's `visor://connect?code=` link) carries its name,
// address and password. A bare Tailscale name works too.

import MessageCache
import SwiftUI
import VisorProtocol
import VisorServices

@MainActor
public final class VisorStore: ObservableObject {
    @Published public private(set) var hosts: [HostConnection] = []
    /// The connect sheet is open. Held here because the Mac opens it from
    /// its menu bar, which is a scene away from the view.
    @Published public var addingComputer = false
    /// A session a notification the user opened is about, for the view to
    /// open; cleared once it has.
    @Published public var opening: NotificationTarget?
    /// Bumped when a host's config changes, so views of the store refresh.
    @Published private var revision = 0
    private let key = "hosts"

    public init() {
        // Screenshot tests: only the canned computer, its rows in memory,
        // and nothing of the real ones read or written.
        if VisorFixture.active {
            Backends.register(FixtureBackend())
            MessageCache.storageProvider = { _ in MemoryStorage() }
            hosts = [HostConnection(config: VisorFixture.config)]
            for host in hosts { observe(host); host.connect() }
            addingComputer = VisorFixture.screen == "connect"
            return
        }
        let saved = VisorHost.settings?.get(key: key) ?? ""
        if !saved.isEmpty, let configs = parseJSON(saved)?.array?.compactMap(HostConfig.init(json:)) {
            var carried = false
            hosts = configs.map { config in
                var config = config
                if config.password.isEmpty {
                    config.password = VisorHost.settings?.secret(key: Self.passwordKey(config.id)) ?? ""
                } else {
                    // Saved with its password, from before secrets: moved.
                    carried = true
                }
                return HostConnection(config: config)
            }
            if carried { save() }
        }
        for host in hosts { observe(host); host.connect() }
        listenForNotifications()
    }

    /// A push token arriving goes to every computer; a notification the
    /// user opens names a session to open.
    private func listenForNotifications() {
        VisorNotificationHandler.shared.onToken = { [weak self] in
            Task { @MainActor in self?.hosts.forEach { $0.registerForPush() } }
        }
        VisorNotificationHandler.shared.onOpen = { [weak self] target in
            Task { @MainActor in self?.opening = target }
        }
    }

    /// The computer a notification names, by the address it goes by.
    public func host(named computer: String) -> HostConnection? {
        hosts.first { $0.config.host == computer } ?? hosts.first { $0.config.name == computer }
    }

    /// Adds (or updates, by address) a computer and connects to it.
    @discardableResult
    public func add(_ config: HostConfig) -> HostConnection {
        if let existing = hosts.first(where: { $0.config.host == config.host }) {
            existing.update { current in
                current.password = config.password
                if !config.name.isEmpty { current.name = config.name }
            }
            existing.connect()
            save()
            return existing
        }
        let host = HostConnection(config: config)
        hosts.append(host)
        observe(host)
        host.connect()
        save()
        return host
    }

    /// A connection code or a `visor://connect` link: the computer it
    /// names is added (or its password updated) and connected. Nil when
    /// the text is neither.
    @discardableResult
    public func open(_ text: String) -> HostConnection? {
        guard let code = ConnectionCode(parsing: text) else { return nil }
        addingComputer = false
        return add(HostConfig(name: code.name, host: code.host, password: code.password))
    }

    public func remove(_ host: HostConnection) {
        host.disconnect()
        hosts.removeAll { $0 === host }
        VisorHost.settings?.setSecret(key: Self.passwordKey(host.id), value: "")
        save()
    }

    /// Where a computer's password is kept, apart from its config.
    static func passwordKey(_ id: String) -> String { "password." + id }

    public func host(for id: String) -> HostConnection? { hosts.first { $0.id == id } }

    /// Links the servers of every connected computer to one another, so
    /// the agents on each reach the sessions on the others: each gives
    /// its connection code, and each is handed the others'. Nil when all
    /// are linked; otherwise what went wrong, per computer.
    public func linkComputers() async -> String? {
        let connected = hosts.filter { $0.state == .connected }
        guard connected.count > 1 else { return "Connect to two or more computers first." }
        var codes: [(host: HostConnection, code: String)] = []
        var problems: [String] = []
        for host in connected {
            do { codes.append((host, try await host.connectionCode())) } catch { problems.append("\(host.config.name): \(Self.describe(error))") }
        }
        for (host, _) in codes {
            for (other, code) in codes where other !== host {
                do { try await host.link(code: code) } catch { problems.append("\(host.config.name) → \(other.config.name): \(Self.describe(error))") }
            }
        }
        return problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? HostConnection.LinkError { return error.message }
        if let status = VisorHost.http?.status(of: error) { return status == 404 ? "its Visor Server is too old to link" : "it answered \(status)" }
        return "not reachable"
    }

    /// The computers answering now: where a new session can go.
    public var connectedHosts: [HostConnection] { hosts.filter { $0.state == .connected } }

    private func observe(_ host: HostConnection) {
        host.onConfigChange = { [weak self] in
            guard let self else { return }
            self.revision += 1
            self.save()
        }
        host.onSessionsChange = { [weak self] in self?.publishWidget() }
    }

    /// The latest sessions on every computer, for the home screen's widget:
    /// published when they change, as JSON the widget reads.
    private var published = ""
    func publishWidget() {
        // The canned computer never reaches the real home screen.
        guard let widget = VisorHost.widget, !VisorFixture.active else { return }
        let json = Self.widgetJSON(hosts.flatMap { host in host.sessions.map { (host.config.name, $0) } })
        guard json != published else { return }
        published = json
        widget.publish(json)
    }

    /// Up to eight live sessions, the latest first: what each is called,
    /// where, its latest words and whether it is working, waiting for
    /// approval or working toward a goal.
    static func widgetJSON(_ sessions: [(computer: String, info: SessionInfo)]) -> String {
        let live = sessions.filter { !$0.info.archived && !$0.info.ended }
            .sorted { ($0.info.updated ?? $0.info.created) > ($1.info.updated ?? $1.info.created) }
            .prefix(8)
        let rows: [JSONValue] = live.map { computer, info in
            let state = info.pendingApproval != nil ? "waiting" : info.busy ? "working" : info.goal != nil ? "goal" : "idle"
            return .object(["computer": .string(computer), "title": .string(info.title.isEmpty ? info.agent.title : info.title),
                            "preview": .string(info.preview ?? ""), "state": .string(state),
                            "updated": .number(info.updated ?? info.created)])
        }
        return JSONValue.object(["sessions": .array(rows)]).encoded()
    }

    private func save() {
        // The canned computer is never saved over the real ones.
        guard !VisorFixture.active else { return }
        // The configs without their passwords; each password as a secret.
        let configs = hosts.map { host -> JSONValue in
            var config = host.config
            VisorHost.settings?.setSecret(key: Self.passwordKey(config.id), value: config.password)
            config.password = ""
            return config.json
        }
        VisorHost.settings?.set(key: key, value: JSONValue.array(configs).encoded())
    }
}
