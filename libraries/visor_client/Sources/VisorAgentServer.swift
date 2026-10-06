import VisorProtocol
import VisorServices

/// A Visor server speaking the wire protocol (docs/protocol.md), reached
/// as its address says: a name on a network (HTTPS at the root), any
/// http(s) URL a proxy, a tunnel or a port gives (`ServerAddress`), or
/// the computer's own SSH (`SSHAddress`, `user@host`), through which the
/// server is reached on its loopback (VisorAgentServer+SSH). `hello` over
/// HTTP first — the server lets this device in on the password, and
/// hands back its name and a token — then the socket at the root for the
/// live channel, logged in with the token, and `/api` for the one-shot
/// calls, the password as the bearer token. Over the host's socket and
/// HTTP services, so the same code runs in a browser.
///
/// The live channel is an accessory. Where it cannot be had — the host
/// has no socket service, or the road does not carry WebSockets — the
/// server is followed by polling instead (VisorAgentServer+Polling): the
/// list of sessions and each open session's state are asked for and held
/// until they change, as the transcript always is. The socket is tried
/// again now and then, and takes over when it opens.
///
/// The channel is kept honest by a heartbeat of its own — a `ping`
/// envelope every 16 s, and a channel that says nothing for 8 s after
/// one is taken as dropped — because a socket that died quietly (a sleep,
/// a change of network) otherwise looks open until TCP gives up. The
/// socket has 4 s to open and have its login answered. It is a message of
/// the protocol, not a WebSocket ping frame, which a browser cannot send.
public final class VisorAgentServer: AgentServer {
    /// How often the channel is asked whether it is still there, and how
    /// long it has to say anything at all before it is taken as dropped.
    static let heartbeatInterval: Int32 = 16_000
    static let heartbeatTimeout: Int32 = 8_000
    /// How long the Mac has to answer the login once the socket is asked
    /// for: the user is waiting on this one.
    static let loginTimeout: Int32 = 4_000
    /// How long the channel has to answer when asked outright, as the app
    /// comes back to the front: an answer over a network takes
    /// milliseconds, and the user is looking.
    static let verifyTimeout: Int32 = 1_000

    private(set) var record: AgentServerRecord
    /// The record's address as an SSH one, when it is one.
    var sshAddress: SSHAddress? { SSHAddress(record.address) }
    /// The SSH connection and the server's address through it, while open.
    var tunnelSession: (any VisorSSHSession)?
    var tunnel: ServerAddress?
    /// Where the server is: the record's address, read as a URL — or,
    /// for an SSH address, the loopback port the tunnel gives, once open.
    var address: ServerAddress? { sshAddress != nil ? tunnel : ServerAddress(record.address) }
    /// What `hello` gave for the channel's login.
    var token: String?
    /// Following by polling instead of the channel (VisorAgentServer+Polling).
    var polling: Polling?
    private var socketID: Int32?
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    /// How many messages this channel has brought: one more after a ping
    /// is the answer to it, whatever the message was.
    private var heard = 0
    /// Whether this channel's socket opened and the login went out.
    private var loggedIn = false

    public init(record: AgentServerRecord) {
        self.record = record
    }

    public func authenticate(_ record: AgentServerRecord) async throws -> String? {
        self.record = record
        if let sshAddress { try await openTunnel(sshAddress) }
        do {
            let hello = try await call("GET", "/hello")
            token = hello.token
            return hello.host.flatMap { $0.isEmpty ? nil : $0 }
        } catch {
            closeTunnel()
            // A 401 is the Mac asking for a password.
            if VisorHost.http?.status(of: error) == 401 { throw AgentServerError.needsAuthentication }
            throw error
        }
    }

    public func openChannel(onEvent: @escaping @MainActor (AgentServerEvent) -> Void) {
        closeSocket()
        guard let address else {
            Task { onEvent(.closed("Bad address")) }
            return
        }
        // No socket to be had here: followed by polling from the start.
        guard let socket = VisorHost.socket else {
            poll(address, onEvent: onEvent)
            return
        }
        let id = socket.open(url: address.socket)
        guard id >= 0 else {
            Task { onEvent(.closed("Bad address")) }
            return
        }
        socketID = id
        heard = 0
        loggedIn = false
        heartbeat = Task { [weak self] in await self?.watch(id, onEvent: onEvent) }
        reader = Task { [weak self] in
            // Events arrive one at a time; the loop ends when the socket is gone.
            while !Task.isCancelled {
                do {
                    let event = try await socket.next(id: id)
                    guard let self, self.socketID == id else { return }
                    if event == "open" {
                        self.loggedIn = true
                        ConnectionLog.shared.note(self.record.name.isEmpty ? self.record.address : self.record.name, "socket open; login sent")
                        self.send(.login(password: self.record.secret, token: self.token, client: AgentServerRecord.clientID))
                    } else if event.hasPrefix("message ") {
                        self.heard += 1
                        // Read off the main actor: a page of earlier rows
                        // is hundreds of them. The loop waits for each, so
                        // messages still arrive in order.
                        let text = String(event.dropFirst(8))
                        let translated = await Task.detached(priority: .userInitiated) { Self.translate(text) }.value
                        guard self.socketID == id else { return }
                        if let translated { onEvent(translated) }
                    } else if event.hasPrefix("close ") || event.hasPrefix("error ") {
                        self.socketID = nil
                        let reason = String(event.split(separator: " ", maxSplits: 1).last ?? "")
                        // Refused before it opened, while the server itself
                        // answered `hello`: a road that carries no WebSocket.
                        // Polling takes over, and the socket is tried later.
                        if !self.loggedIn, let address = self.address {
                            self.heartbeat?.cancel()
                            self.heartbeat = nil
                            socket.disconnect(id: id)
                            self.poll(address, onEvent: onEvent, after: "the socket was refused: \(reason)")
                            return
                        }
                        onEvent(.closed(reason))
                        return
                    }
                } catch {
                    guard let self, self.socketID == id else { return }
                    self.socketID = nil
                    onEvent(.closed("connection lost"))
                    return
                }
            }
        }
    }

    /// Watches a channel for as long as it is the one open: the login must
    /// be answered in time, and after that each heartbeat must be followed
    /// by something — the `pong`, or anything else the Mac says. A channel
    /// that stays silent is closed and reported as dropped, which is what
    /// starts the connection's retries.
    private func watch(_ id: Int32, onEvent: @escaping @MainActor (AgentServerEvent) -> Void) async {
        guard let socket = VisorHost.socket else { return }
        await socket.delay(milliseconds: Self.loginTimeout)
        guard socketID == id, !Task.isCancelled else { return }
        // A socket that opened and was not answered is a server that is
        // not there: dropped. One that never opened at all is a road that
        // may carry no WebSocket: polling takes over, and the socket is
        // tried again later.
        if heard == 0 {
            if loggedIn { return drop(id, "No answer to the login", onEvent) }
            socketID = nil
            reader?.cancel()
            reader = nil
            socket.disconnect(id: id)
            guard let address else { return onEvent(.closed("The socket did not open")) }
            return poll(address, onEvent: onEvent, after: "the socket did not open")
        }
        while true {
            await socket.delay(milliseconds: Self.heartbeatInterval)
            guard socketID == id, !Task.isCancelled else { return }
            let before = heard
            send(.ping())
            await socket.delay(milliseconds: Self.heartbeatTimeout)
            guard socketID == id, !Task.isCancelled else { return }
            if heard == before { return drop(id, "No answer to a heartbeat", onEvent) }
        }
    }

    public func verifyChannel() async -> Bool {
        guard let id = socketID, let socket = VisorHost.socket else { return false }
        let before = heard
        send(.ping())
        await socket.delay(milliseconds: Self.verifyTimeout)
        // Another channel since: that one is not this question's to answer.
        return socketID != id || heard != before
    }

    private func drop(_ id: Int32, _ reason: String, _ onEvent: @MainActor (AgentServerEvent) -> Void) {
        socketID = nil
        reader?.cancel()
        reader = nil
        VisorHost.socket?.disconnect(id: id)
        onEvent(.closed(reason))
    }

    /// A message from the Mac, as the event it means. Nil for one that is
    /// not an envelope, and for the answer to a heartbeat — a `pong`, or
    /// from a Mac older than the heartbeat, its complaint about the ping.
    nonisolated static func translate(_ text: String) -> AgentServerEvent? {
        guard let envelope = Envelope.decode(text) else { return nil }
        switch envelope.type {
        case "pong": return nil
        case "error" where envelope.message == "Unknown message ping": return nil
        case "welcome": return .welcome(name: envelope.host ?? "", sessions: envelope.sessions ?? [], catalogs: envelope.catalogs ?? [])
        case "sessions": return .sessions(envelope.sessions ?? [])
        case "catalogs": return .catalogs(envelope.catalogs ?? [])
        case "account":
            guard let account = envelope.account, let agent = envelope.agent else { return nil }
            return .account(account, of: agent)
        case "error": return envelope.message == "Wrong password" ? .refused(envelope.message ?? "") : .failed(envelope.message ?? "Rejected")
        default: return .session(envelope)
        }
    }

    public func closeChannel() {
        closeSocket()
        closeTunnel()
    }

    /// Ends the channel, the socket or the polling, and leaves the tunnel
    /// for the next channel.
    private func closeSocket() {
        stopPolling()
        heartbeat?.cancel()
        heartbeat = nil
        reader?.cancel()
        reader = nil
        if let socketID { VisorHost.socket?.disconnect(id: socketID) }
        socketID = nil
    }

    public func delay(milliseconds: Int32) async {
        // A host with no socket service has no timer to lend: wait all the
        // same, so nothing that paces itself by this spins.
        guard let socket = VisorHost.socket else {
            try? await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
            return
        }
        await socket.delay(milliseconds: milliseconds)
    }

    func send(_ envelope: Envelope) {
        guard let socketID else { return }
        VisorHost.socket?.send(id: socketID, text: envelope.encoded())
    }

    /// One REST call, returning the answer as an envelope.
    func call(_ method: String, _ path: String, _ body: Envelope? = nil) async throws -> Envelope {
        let text = try await callText(method, path, body: body?.encoded() ?? "")
        return Envelope.decode(text, defaultType: "reply") ?? Envelope(type: "reply")
    }

    /// One REST call, returning the answer's body as it came.
    func callText(_ method: String, _ path: String, body: String) async throws -> String {
        guard let http = VisorHost.http else { throw AgentServerError.message("No HTTP service on this host") }
        guard let address else { throw AgentServerError.message("Bad address") }
        return try await http.request(method: method, url: address.api + path, body: body, authorization: record.secret)
    }

    static func escape(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            if (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 45 || byte == 46 || byte == 95 || byte == 126 || byte == 47 {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += "%" + String(byte, radix: 16, uppercase: true).leftPadded(2)
            }
        }
        return out
    }
}
