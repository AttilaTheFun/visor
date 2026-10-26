import VisorProtocol
import VisorServices

// Each operation of the protocol, as the wire protocol carries it: the
// live ones as envelopes over the socket, the one-shot ones as REST calls.
extension VisorAgentServer {
    // MARK: Over the live channel

    // Over the channel; by polling, each is asked for in its one-shot
    // form.
    public func subscribe(_ session: String) {
        if polling != nil { pollState(of: session) } else { send(.subscribe(session: session)) }
    }
    public func signIn(_ session: String, code: String) {
        if polling != nil {
            Task { _ = try? await call("POST", "/sessions/\(Self.escape(session))/signIn", .signIn(session: session, code: code)) }
        } else {
            send(.signIn(session: session, code: code))
        }
    }
    public func unsubscribe(_ session: String) {
        if let polling { polling.states.removeValue(forKey: session)?.cancel() } else { send(.unsubscribe(session: session)) }
    }
    public func acknowledge(_ session: String) {
        if polling != nil { Task { _ = try? await call("POST", "/sessions/\(Self.escape(session))/acknowledge") } }
        else { send(.acknowledge(session: session)) }
    }
    public func loadEarlier(_ session: String, before: String) {
        if polling != nil { pollEarlier(of: session, before: before) } else { send(.earlier(session: session, before: before)) }
    }

    // MARK: Sessions

    public func sessions() async throws -> [SessionInfo] {
        try await call("GET", "/sessions").sessions ?? []
    }

    public func startSession(id: String, agent: AgentKind, cwd: String, title: String, skipPermissions: Bool, resume: String?) async throws -> [SessionInfo] {
        try await call("POST", "/sessions", .start(id: id, agent: agent, cwd: cwd, title: title, skipPermissions: skipPermissions, resume: resume)).sessions ?? []
    }

    public func startSessionInContainer(id: String, agent: AgentKind, cwd: String, title: String, skipPermissions: Bool,
                                        size: ContainerSize?) async throws -> [SessionInfo] {
        try await call("POST", "/sessions", .startInContainer(id: id, agent: agent, cwd: cwd, title: title, skipPermissions: skipPermissions,
                                                              size: size)).sessions ?? []
    }

    public func contain(session: String, into: Bool, size: ContainerSize?) async throws -> [SessionInfo] {
        try await call("POST", "/sessions/\(session)/contain", .contain(session: session, into, size: size)).sessions ?? []
    }

    public func act(_ action: SessionAction, on session: String) async throws -> [SessionInfo] {
        let base = "/sessions/\(session)"
        let reply: Envelope
        switch action {
        case .stop: reply = try await call("POST", base + "/stop")
        case .unqueue(let text):
            var e = Envelope(type: "unqueue"); e.session = session; e.text = text
            reply = try await call("POST", base + "/unqueue", e)
        case .permissions(let skip): reply = try await call("POST", base + "/permissions", .permissions(session: session, skipPermissions: skip))
        case .settings(let model, let effort): reply = try await call("POST", base + "/settings", .settings(session: session, model: model, effort: effort))
        case .approve(let id, let allow, let answers):
            reply = try await call("POST", base + "/approve", .approve(session: session, id: id, allow: allow, answers: answers))
        case .rename(let title): reply = try await call("POST", base + "/rename", .rename(session: session, title: title))
        case .archive: reply = try await call("POST", base + "/archive")
        case .unarchive: reply = try await call("POST", base + "/unarchive")
        case .restartAgent: reply = try await call("POST", base + "/restartAgent")
        case .stopAgent: reply = try await call("POST", base + "/stopAgent")
        case .startAgent: reply = try await call("POST", base + "/startAgent")
        case .keepBranch: reply = try await call("POST", base + "/keepBranch")
        case .continueBranch: reply = try await call("POST", base + "/continueBranch")
        case .end: reply = try await call("DELETE", base)
        }
        return reply.sessions ?? []
    }

    public func sendMessage(_ session: String, text: String, images: [String]) async throws -> [SessionInfo] {
        try await call("POST", "/sessions/\(session)/send", .send(session: session, text: text, images: images)).sessions ?? []
    }

    public func transcript(of session: String, since revision: Int, generation: Int, after: String?) async throws -> Envelope {
        let page = after.map { "&after=" + Self.escape($0) } ?? ""
        let text = try await callText("GET", "/sessions/\(session)/transcript?since=\(revision)&generation=\(generation)" + page, body: "")
        // Read off the main actor: the whole of a thread is hundreds of rows.
        let envelope = await Task.detached(priority: .userInitiated) {
            Envelope.decode(text, defaultType: "transcript")
        }.value
        guard let envelope else { throw AgentServerError.message("Not a transcript") }
        return envelope
    }

    public func commands(for session: String) async throws -> [SlashCommand] {
        try await call("GET", "/sessions/\(session)/commands").commands ?? []
    }

    public func resumable(agent: AgentKind, cwd: String) async throws -> [ResumableSession] {
        try await call("GET", "/resumable?agent=\(agent.rawValue)&cwd=" + Self.escape(cwd)).resumable ?? []
    }

    public func account(of agent: AgentKind) async throws -> AgentAccount? {
        try await call("GET", "/account?agent=\(agent.rawValue)").account
    }

    public func relocateSessions(from cwd: String, to destination: String) async throws -> [SessionInfo] {
        var e = Envelope(type: "relocate")
        e.path = cwd
        e.cwd = destination
        return try await call("POST", "/relocate", e).sessions ?? []
    }

    // MARK: Folders and files

    public func folders(at path: String) async throws -> FolderListing {
        let reply = try await call("GET", "/folders?path=" + Self.escape(path))
        return FolderListing(path: reply.path ?? path, folders: reply.folders ?? [], exists: reply.exists ?? true)
    }

    public func makeFolder(_ path: String) async throws -> String {
        var body = Envelope(type: "mkdir"); body.path = path
        return try await call("POST", "/folders", body).path ?? path
    }

    public func fileData(path: String) async throws -> String {
        let text = try await callText("GET", "/file?path=" + Self.escape(path), body: "")
        // A picture is megabytes of quoted base64: read off the main actor,
        // whose frames it would otherwise hold up as each one arrives.
        let data = await Task.detached(priority: .userInitiated) {
            Envelope.decode(text, defaultType: "reply")?.text
        }.value
        guard let data, !data.isEmpty else { throw AgentServerError.message("No such file") }
        return data
    }

    public func upload(base64: String, name: String) async throws -> String {
        var body = Envelope(type: "file")
        body.text = base64
        body.title = name
        let reply = try await call("POST", "/file", body)
        guard let path = reply.path, !path.isEmpty else { throw AgentServerError.message("The upload was not taken") }
        return path
    }

    public func search(_ query: String) async throws -> [SearchHit] {
        let text = try await callText("GET", "/search?q=" + Self.escape(query), body: "")
        return (parseJSON(text)?["hits"].array ?? []).compactMap { hit in
            guard let session = hit["session"].string, let message = hit["id"].string else { return nil }
            return SearchHit(session: session, message: message, role: hit["role"].string ?? "", snippet: hit["snippet"].string ?? "",
                             title: hit["title"].string ?? "", cwd: hit["cwd"].string ?? "")
        }
    }

    // MARK: Pushes and codes

    public func registerPush(token: String, platform: String, environment: String, topic: String) async throws -> Bool {
        var e = Envelope(type: "push")
        e.deviceToken = token
        e.platform = platform
        e.pushEnvironment = environment
        e.pushTopic = topic
        // Whether the Mac sends pushes (it has an APNs key).
        return try await call("POST", "/push", e).exists ?? false
    }

    public func connectionCodes() async throws -> ConnectionCodes {
        let reply = try await call("GET", "/codes")
        guard let codes = reply.codes else { throw AgentServerError.message(reply.error ?? "No connection code") }
        return codes
    }

    // MARK: The relay

    public var relays: Bool { true }

    public func relay(_ report: DirectoryReport) async throws -> [RelayMessage] {
        var body = Envelope(type: "relay")
        body.report = report
        let reply = try await call("POST", "/relay", body)
        if let error = reply.error { throw AgentServerError.message(error) }
        return reply.relayed ?? []
    }

    public func deliver(_ message: RelayMessage) async throws -> RelayReceipt {
        var body = Envelope(type: "relay")
        body.relayed = [message]
        let reply = try await call("POST", "/relay/deliver", body)
        guard let receipt = reply.receipt else { throw AgentServerError.message(reply.error ?? "No receipt") }
        return receipt
    }

    public func confirm(_ receipt: RelayReceipt) async throws {
        var body = Envelope(type: "relay")
        body.receipt = receipt
        let reply = try await call("POST", "/relay/receipt", body)
        if let error = reply.error { throw AgentServerError.message(error) }
    }

    public func authorizeSSHKey(_ line: String) async throws {
        var body = Envelope(type: "ssh")
        body.text = line
        let reply = try await call("POST", "/ssh/keys", body)
        if let error = reply.error { throw AgentServerError.message(error) }
    }
}
