import VisorProtocol
import VisorServices

// Each operation of the protocol, as the wire protocol carries it: the
// live ones as envelopes over the socket, the one-shot ones as REST calls.
extension WireAgentServer {
    // MARK: Over the live channel

    // Over the channel; by polling, what has a one-shot form is asked
    // for that way, and the terminal's bytes, which only the channel
    // carries, are not.
    public func subscribe(_ session: String) {
        if polling != nil { pollState(of: session) } else { send(.subscribe(session: session)) }
    }
    public func assumeControl(_ session: String, cols: Int, rows: Int) { send(.assumeControl(session: session, cols: cols, rows: rows)) }
    public func acknowledge(_ session: String) {
        if polling != nil { Task { _ = try? await call("POST", "/sessions/\(Self.escape(session))/acknowledge") } }
        else { send(.acknowledge(session: session)) }
    }
    public func loadEarlier(_ session: String, before: String) {
        if polling != nil { pollEarlier(of: session, before: before) } else { send(.earlier(session: session, before: before)) }
    }
    public func sendInput(_ session: String, data: String) { send(.input(session: session, data: data)) }
    public func resize(_ session: String, cols: Int, rows: Int) { send(.resize(session: session, cols: cols, rows: rows)) }

    // MARK: Sessions

    public func sessions() async throws -> [SessionInfo] {
        try await call("GET", "/sessions").sessions ?? []
    }

    public func startSession(id: String, agent: AgentKind, cwd: String, title: String, skipPermissions: Bool, resume: String?) async throws -> [SessionInfo] {
        try await call("POST", "/sessions", .start(id: id, agent: agent, cwd: cwd, title: title, skipPermissions: skipPermissions, resume: resume)).sessions ?? []
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
        case .approve(let id, let allow): reply = try await call("POST", base + "/approve", .approve(session: session, id: id, allow: allow))
        case .rename(let title): reply = try await call("POST", base + "/rename", .rename(session: session, title: title))
        case .archive: reply = try await call("POST", base + "/archive")
        case .unarchive: reply = try await call("POST", base + "/unarchive")
        case .end: reply = try await call("DELETE", base)
        }
        return reply.sessions ?? []
    }

    public func sendMessage(_ session: String, text: String, images: [String]) async throws -> [SessionInfo] {
        try await call("POST", "/sessions/\(session)/send", .send(session: session, text: text, images: images)).sessions ?? []
    }

    public func transcript(of session: String, since revision: Int, generation: Int) async throws -> Envelope {
        let text = try await callText("GET", "/sessions/\(session)/transcript?since=\(revision)&generation=\(generation)", body: "")
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

    // MARK: Pushes and links

    public func registerPush(token: String, platform: String, environment: String, topic: String) async throws -> Bool {
        var e = Envelope(type: "push")
        e.deviceToken = token
        e.platform = platform
        e.pushEnvironment = environment
        e.pushTopic = topic
        // Whether the Mac sends pushes (it has an APNs key).
        return try await call("POST", "/push", e).exists ?? false
    }

    public func connectionCode() async throws -> String {
        let reply = try await call("GET", "/code")
        guard let code = reply.text, !code.isEmpty else { throw AgentServerError.message("No connection code") }
        return code
    }

    public func link(code: String) async throws {
        var body = Envelope(type: "link")
        body.text = code
        let reply = try await call("POST", "/link", body)
        if let error = reply.error { throw AgentServerError.message(error) }
    }
}
