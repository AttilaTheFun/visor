// The saved computers and their live connections. Configs persist through
// the host's settings service (UserDefaults on Apple, localStorage on the
// web; the password with them: the host is the user's own machine on their
// own network); connections are made on launch.
//
// A computer is added in one step: its connection code (pasted, or a
// scanned QR code's `visor://connect?code=` link) carries its name,
// address and password. A bare Tailscale name works too.

import SwiftUI
import VisorProtocol
import VisorServices

@MainActor
public final class VisorStore: ObservableObject {
    @Published public private(set) var hosts: [HostConnection] = []
    /// The connect sheet is open. Held here because the Mac opens it from
    /// its menu bar, which is a scene away from the view.
    @Published public var addingComputer = false
    /// Bumped when a host's config changes, so views of the store refresh.
    @Published private var revision = 0
    private let key = "hosts"

    public init() {
        let saved = VisorHost.settings?.get(key: key) ?? ""
        if !saved.isEmpty, let configs = parseJSON(saved)?.array?.compactMap(HostConfig.init(json:)) {
            hosts = configs.map(HostConnection.init)
        }
        for host in hosts { observe(host); host.connect() }
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
        save()
    }

    public func host(for id: String) -> HostConnection? { hosts.first { $0.id == id } }

    /// The computers answering now: where a new session can go.
    public var connectedHosts: [HostConnection] { hosts.filter { $0.state == .connected } }

    private func observe(_ host: HostConnection) {
        host.onConfigChange = { [weak self] in
            guard let self else { return }
            self.revision += 1
            self.save()
        }
    }

    private func save() {
        VisorHost.settings?.set(key: key, value: JSONValue.array(hosts.map(\.config.json)).encoded())
    }
}
