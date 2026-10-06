// A Visor server reached over SSH: the computer's `sshd` is the road in,
// authenticated by this device's key, and the server itself is reached
// on its own loopback through a forwarded port. Everything else is the
// HTTP server over that port: the sign-in with the password, the live
// channel, the one-shot calls, the polling fallback. Nothing has to be
// open on the computer's network but SSH, and no road of Visor's own is
// involved.

import VisorProtocol
import VisorServices

@MainActor
public final class SSHAgentServer: AgentServer {
    private(set) var record: AgentServerRecord
    /// The SSH connection, and the HTTP server through it, while open.
    private var session: (any VisorSSHSession)?
    private var inner: HTTPAgentServer?

    public init(record: AgentServerRecord) {
        self.record = record
    }

    /// `user@host[:port]`, as the record's address holds it.
    struct Address: Equatable {
        var user: String
        var host: String
        var port: Int

        init?(_ text: String) {
            var value = Substring(text)
            while let first = value.first, first.isWhitespace || first.isNewline { value = value.dropFirst() }
            while let last = value.last, last.isWhitespace || last.isNewline { value = value.dropLast() }
            if value.lowercased().hasPrefix("ssh://") { value = value.dropFirst(6) }
            guard let at = value.firstIndex(of: "@") else { return nil }
            user = String(value[..<at])
            var rest = value[value.index(after: at)...]
            port = 22
            if let colon = rest.lastIndex(of: ":"), let number = Int(rest[rest.index(after: colon)...]) {
                port = number
                rest = rest[..<colon]
            }
            host = String(rest)
            guard !user.isEmpty, !host.isEmpty else { return nil }
        }
    }

    /// Where the computer's host key is kept, by address.
    static func hostKeySetting(_ address: Address) -> String { "ssh.hostkey.\(address.user)@\(address.host):\(address.port)" }

    /// The server's port on the computer's loopback.
    static let serverPort = Int(Envelope.defaultPort)

    public func authenticate(_ record: AgentServerRecord) async throws -> String? {
        self.record = record
        guard let ssh = VisorHost.ssh else { throw AgentServerError.message("No SSH on this host") }
        guard let address = Address(record.address) else { throw AgentServerError.message("The address is not user@host") }
        closeChannel()
        let setting = Self.hostKeySetting(address)
        let known = VisorHost.settings?.get(key: setting) ?? ""
        let session: any VisorSSHSession
        do {
            session = try await ssh.connect(user: address.user, host: address.host, port: address.port, hostKey: known.isEmpty ? nil : known)
        } catch VisorSSHError.hostKeyChanged {
            throw AgentServerError.message("\(address.host)'s host key has changed. If the computer was reinstalled, forget it here and add it again.")
        } catch VisorSSHError.keyRefused {
            throw AgentServerError.needsAuthentication
        } catch VisorSSHError.unreachable(let why) {
            throw AgentServerError.message("\(address.host) was not reached over SSH: \(why)")
        }
        if known.isEmpty { VisorHost.settings?.set(key: setting, value: session.hostKey) }
        let port = try await session.forward(toPort: Self.serverPort)
        self.session = session
        let inner = HTTPAgentServer(record: AgentServerRecord(id: record.id, name: record.name, address: "http://127.0.0.1:\(port)",
                                                              secret: record.secret, everConnected: record.everConnected,
                                                              provider: HTTPAgentServerProvider.name))
        self.inner = inner
        do {
            return try await inner.authenticate(inner.record)
        } catch {
            closeChannel()
            throw error
        }
    }

    private var server: HTTPAgentServer {
        get throws {
            guard let inner else { throw AgentServerError.message("Not connected over SSH") }
            return inner
        }
    }

    public func openChannel(onEvent: @escaping @MainActor (AgentServerEvent) -> Void) {
        guard let inner else { return onEvent(.closed("Not connected over SSH")) }
        inner.openChannel { [weak self] event in
            // The tunnel is gone with the channel: opened anew next time.
            if case .closed = event { self?.closeTunnel() }
            onEvent(event)
        }
    }

    public func closeChannel() {
        inner?.closeChannel()
        closeTunnel()
    }

    private func closeTunnel() {
        session?.close()
        session = nil
        inner = nil
    }

    public func verifyChannel() async -> Bool { await inner?.verifyChannel() ?? false }

    public func delay(milliseconds: Int32) async {
        if let inner { await inner.delay(milliseconds: milliseconds) } else { await HTTPAgentServer(record: record).delay(milliseconds: milliseconds) }
    }

    public func subscribe(_ session: String) { inner?.subscribe(session) }
    public func assumeControl(_ session: String, cols: Int, rows: Int) { inner?.assumeControl(session, cols: cols, rows: rows) }
    public func acknowledge(_ session: String) { inner?.acknowledge(session) }
    public func loadEarlier(_ session: String, before: String) { inner?.loadEarlier(session, before: before) }
    public func sendInput(_ session: String, data: String) { inner?.sendInput(session, data: data) }
    public func resize(_ session: String, cols: Int, rows: Int) { inner?.resize(session, cols: cols, rows: rows) }

    public func sessions() async throws -> [SessionInfo] { try await server.sessions() }
    public func startSession(id: String, agent: AgentKind, cwd: String, title: String, skipPermissions: Bool, resume: String?) async throws -> [SessionInfo] {
        try await server.startSession(id: id, agent: agent, cwd: cwd, title: title, skipPermissions: skipPermissions, resume: resume)
    }
    public func act(_ action: SessionAction, on session: String) async throws -> [SessionInfo] { try await server.act(action, on: session) }
    public func sendMessage(_ session: String, text: String, images: [String]) async throws -> [SessionInfo] {
        try await server.sendMessage(session, text: text, images: images)
    }
    public func transcript(of session: String, since revision: Int, generation: Int) async throws -> Envelope {
        try await server.transcript(of: session, since: revision, generation: generation)
    }
    public func commands(for session: String) async throws -> [SlashCommand] { try await server.commands(for: session) }
    public func resumable(agent: AgentKind, cwd: String) async throws -> [ResumableSession] { try await server.resumable(agent: agent, cwd: cwd) }
    public func relocateSessions(from cwd: String, to destination: String) async throws -> [SessionInfo] {
        try await server.relocateSessions(from: cwd, to: destination)
    }
    public func folders(at path: String) async throws -> FolderListing { try await server.folders(at: path) }
    public func makeFolder(_ path: String) async throws -> String { try await server.makeFolder(path) }
    public func fileData(path: String) async throws -> String { try await server.fileData(path: path) }
    public func upload(base64: String, name: String) async throws -> String { try await server.upload(base64: base64, name: name) }
    public func search(_ query: String) async throws -> [SearchHit] { try await server.search(query) }
    public func registerPush(token: String, platform: String, environment: String, topic: String) async throws -> Bool {
        try await server.registerPush(token: token, platform: platform, environment: environment, topic: topic)
    }
    public func connectionCode() async throws -> String { try await server.connectionCode() }
    public func link(code: String) async throws { try await server.link(code: code) }
}
