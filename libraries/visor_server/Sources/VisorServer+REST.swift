// The REST side of the protocol: one request, one answer (a transcript's
// long poll holds its answer until there is something to say).

import ClaudeTranscript
import MessageCache
import Foundation
import VisorProtocol

extension VisorServer {
    func transcriptJSON(_ record: SessionRecord, since: Int?) -> HTTPResponse {
        .json(record.transcriptEnvelope(since: since).encoded())
    }

    /// Answers everyone waiting on this session's transcript with the
    /// rows changed since the revision each holds.
    func answerTranscriptWaiters(for record: SessionRecord) {
        guard let waiting = transcriptWaiters.removeValue(forKey: record.info.id), !waiting.isEmpty else { return }
        // A delta while the generation holds; the whole if it moved on.
        for waiter in waiting {
            waiter.respond(transcriptJSON(record, since: waiter.generation == record.generation ? waiter.revision : nil))
        }
    }

    func route(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        // A peer's API, read here and carried there.
        if let target = Self.relayTarget(request.path) {
            guard authorized(request) else { return respond(refusal(request)) }
            return relay(target, request, respond: respond)
        }
        let path = Self.apiPath(request.path.split(separator: "?").first.map(String.init) ?? request.path)
        let parts = path.split(separator: "/").map(String.init)
        if request.method == "GET", parts.count == 3, parts[0] == "sessions", parts[2] == "commands", authorized(request) {
            guard let record = session(parts[1]) else { return respond(HTTPResponse(404, "{\"error\":\"no such session\"}")) }
            var e = Envelope(type: "commands")
            e.session = record.info.id
            e.commands = commands(for: record)
            return respond(.json(e.encoded()))
        }
        if request.method == "GET", parts.count == 3, parts[0] == "sessions", parts[2] == "state", authorized(request) {
            guard let record = session(parts[1]) else { return respond(HTTPResponse(404, "{\"error\":\"no such session\"}")) }
            return answerState(of: record, since: Self.query(request.path)["since"].flatMap(Int.init), respond: respond)
        }
        if request.method == "GET", parts.count == 3, parts[0] == "sessions", parts[2] == "earlier", authorized(request) {
            guard let record = session(parts[1]) else { return respond(HTTPResponse(404, "{\"error\":\"no such session\"}")) }
            guard let before = Self.query(request.path)["before"], !before.isEmpty else { return respond(HTTPResponse(400, "{\"error\":\"before?\"}")) }
            return answerEarlier(of: record, before: before, respond: respond)
        }
        if request.method == "GET", parts.count == 1, parts[0] == "sessions", authorized(request) {
            return answerSessions(since: Self.query(request.path)["since"].flatMap(Int.init), respond: respond)
        }
        if request.method == "GET", parts.count == 3, parts[0] == "sessions", parts[2] == "transcript", authorized(request) {
            guard let record = session(parts[1]) else { return respond(HTTPResponse(404, "{\"error\":\"no such session\"}")) }
            record.followFileIfNeeded()
            if record.onRevision == nil { record.onRevision = { [weak self, weak record] in
                guard let self, let record else { return }
                self.answerTranscriptWaiters(for: record)
            } }
            let query = Self.query(request.path)
            let had = (query["since"] ?? query["revision"]).flatMap(Int.init)
            // A delta only for a client of this generation; any other (a
            // first sync, a client from before a restart) gets the whole.
            // (A client that does not say its generation is taken to be
            // current, as before, rather than answered at once with the
            // whole over and over.)
            let current = query["generation"].flatMap(Int.init).map { $0 == record.generation } ?? true
            // Held only while the client has exactly what there is.
            guard current, had == record.revision else {
                return respond(transcriptJSON(record, since: current ? had.map { $0 > record.revision ? -1 : $0 } : nil))
            }
            transcriptWaiters[record.info.id, default: []].append((revision: record.revision, generation: record.generation, respond: respond))
            Task { [weak self, weak record] in
                try? await Task.sleep(for: .seconds(Self.transcriptHold))
                guard let self, let record else { return }
                // Still waiting after the hold: answered with what there
                // is (nothing new), so the client asks again.
                self.answerTranscriptWaiters(for: record)
            }
            return
        }
        respond(route(request))
    }

    func route(_ request: HTTPRequest) -> HTTPResponse {
        guard authorized(request) else { return refusal(request) }
        var path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        path = Self.apiPath(path)
        let parts = path.split(separator: "/").map(String.init)
        let call = RESTCall(request: request, parts: parts, query: Self.query(request.path), body: Envelope.decodeBody(request.body))
        return switch (request.method, parts.count, parts.first) {
        case ("GET", 1, "hello"): restHello(call)
        case ("GET", 1, "search"): restSearch(call)
        case ("GET", 1, "sessions"): restListSessions(call)
        case ("GET", 1, "folders"): restListFolders(call)
        case ("POST", 1, "folders"): restMakeFolder(call)
        case ("GET", 1, "resumable"): restResumable(call)
        case ("GET", 1, "file"): restReadFile(call)
        case ("POST", 1, "file"): restSaveFile(call)
        case ("POST", 1, "relocate"): restRelocateSessions(call)
        case ("POST", 1, "agent"): restLinkedAgent(call)
        case ("GET", 1, "code"): restCode(call)
        case ("POST", 2, "push") where parts[1] == "key": restSetPushKey(call)
        case ("POST", 2, "push") where parts[1] == "test": restTestPush(call)
        case ("POST", 1, "push"): restRegisterPushDevice(call)
        case ("POST", 1, "link"): restLinkBack(call)
        case ("POST", 1, "unlink"): restUnlink(call)
        case ("GET", 1, "peers"): restPeers(call)
        case ("POST", 1, "peers"): restTakePeers(call)
        case ("POST", 2, "ssh") where parts[1] == "keys": restAuthorizeSSHKey(call)
        case ("POST", 1, "restart"): restRestart(call)
        case ("POST", 1, "quit"): restQuit(call)
        case ("POST", 1, "sessions"): restStartSession(call)
        case ("DELETE", 2, "sessions"): restEndSession(call)
        case ("POST", 3, "sessions"): restSessionAction(call)
        default: HTTPResponse(404, "{\"error\":\"not found\"}")
        }
    }

    /// One request, taken apart: its path's parts after `/api`, its query,
    /// and its body as an envelope.
    struct RESTCall {
        let request: HTTPRequest
        let parts: [String]
        let query: [String: String]
        let body: Envelope
    }

    /// The sessions and the catalogs, as `welcome` carries them.
    private func sessionsJSON() -> String { sessionsEnvelope().encoded() }

    /// The client is in (by the path's word or the password): its
    /// name for this computer, whose it is, and a token to log
    /// the socket in with.
    private func restHello(_ call: RESTCall) -> HTTPResponse {
        var e = Envelope.hello(host: hostName, login: "", token: issueToken())
        e.id = id
        if isStandalone {
            // Reached only where the client found it: nothing more to learn.
            e.standalone = true
        } else {
            e.addresses = ownAddresses
            e.sshKey = ownSSHKey
        }
        return .json(e.encoded())
    }

    /// The network as this server knows it: itself, and its peers with
    /// their addresses and passwords (the client is let in already).
    private func restPeers(_ call: RESTCall) -> HTTPResponse {
        var e = Envelope(type: "peers")
        e.id = id
        e.host = hostName
        // Standing alone: no addresses, no computers, to anyone.
        e.addresses = isStandalone ? [] : ownAddresses
        e.peers = isStandalone ? [] : peers
        return .json(e.encoded())
    }

    /// A device's SSH public key (`text`), into this user's authorized
    /// keys, so the device comes in over SSH next.
    private func restAuthorizeSSHKey(_ call: RESTCall) -> HTTPResponse {
        guard let line = call.body.text, !line.isEmpty else { return HTTPResponse(400, Envelope.error("A public key line is required").encoded()) }
        if let problem = authorizeSSHKey(line) { return HTTPResponse(400, Envelope.error(problem).encoded()) }
        return .json(Envelope(type: "ssh").encoded())
    }

    /// Computers a client or a peer tells this server of; what is news
    /// is kept and passed on. The teller, when a peer, is named in the
    /// relay header so it is not told back.
    private func restTakePeers(_ call: RESTCall) -> HTTPResponse {
        guard let told = call.body.peers, !told.isEmpty else { return HTTPResponse(400, Envelope.error("Peers are required").encoded()) }
        // Standing alone, it is introduced to no one.
        guard !isStandalone else { return .json(Envelope(type: "peers").encoded()) }
        let teller = call.request.headers["x-visor-relay"]?.split(separator: ",").last.map(String.init)
        adopt(told, from: teller)
        return .json(Envelope(type: "peers").encoded())
    }

    /// Rows whose words match, across every session: `q` is the
    /// words, each required.
    private func restSearch(_ call: RESTCall) -> HTTPResponse {
        let words = call.query["q"] ?? ""
        // The cache keys a session by the agent's own id; a hit names
        // the session as clients know it.
        let hits = ServerCache.shared.search(words).compactMap { hit -> [String: Any]? in
            guard let record = session(hit.session) else { return nil }
            return ["session": hit.session, "id": hit.messageID, "role": hit.role.rawValue,
                    "snippet": hit.snippet, "title": record.info.title, "cwd": record.info.cwd]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["type": "search", "query": words, "hits": hits])) ?? Data("{}".utf8)
        return .json(String(decoding: data, as: UTF8.self))
    }

    private func restListSessions(_ call: RESTCall) -> HTTPResponse {
        .json(sessionsEnvelope().encoded())
    }

    private func restListFolders(_ call: RESTCall) -> HTTPResponse {
        var e = Envelope(type: "folders")
        e.path = HostFolders.resolve(call.query["path"] ?? "~")
        e.folders = HostFolders.list(call.query["path"] ?? "~")
        e.exists = HostFolders.exists(call.query["path"] ?? "~")
        return .json(e.encoded())
    }

    private func restMakeFolder(_ call: RESTCall) -> HTTPResponse {
        guard let path = call.body.path, !path.isEmpty else { return HTTPResponse(400, "{\"error\":\"path required\"}") }
        guard HostFolders.make(path) else { return HTTPResponse(400, "{\"error\":\"could not create the folder\"}") }
        var e = Envelope(type: "folders")
        e.path = HostFolders.resolve(path)
        e.folders = HostFolders.list(path)
        return .json(e.encoded())
    }

    private func restResumable(_ call: RESTCall) -> HTTPResponse {
        guard let agent = call.query["agent"].flatMap(AgentKind.init(wire:)) else { return HTTPResponse(400, "{\"error\":\"agent required\"}") }
        var e = Envelope(type: "resumable")
        e.resumable = harnesses.harness(for: agent)?.resumable(cwd: call.query["cwd"] ?? "") ?? []
        return .json(e.encoded())
    }

    /// A picture the transcript named. Base64 in `text`, because
    /// this side of the protocol speaks JSON and nothing else.
    private func restReadFile(_ call: RESTCall) -> HTTPResponse {
        guard let path = call.query["path"], !path.isEmpty else { return HTTPResponse(400, "{\"error\":\"path required\"}") }
        guard let data = AgentImages.read(path: path) else { return HTTPResponse(404, "{\"error\":\"no file there\"}") }
        var e = Envelope(type: "file")
        e.path = path
        e.text = data
        return .json(e.encoded())
    }

    /// Something the user attached: base64 in `text`, a name in
    /// `title`. It is written down and the path comes back, which
    /// is what the agent is then told to look at.
    private func restSaveFile(_ call: RESTCall) -> HTTPResponse {
        guard let data = call.body.text, !data.isEmpty else { return HTTPResponse(400, "{\"error\":\"text required\"}") }
        guard let path = AgentImages.save(base64: data, mediaType: nil, name: call.body.title) else {
            return HTTPResponse(400, Envelope.error("Those were not bytes we could write").encoded())
        }
        var e = Envelope(type: "file")
        e.path = path
        return .json(e.encoded())
    }

    /// A project's folder was renamed or moved. `path` is where it
    /// was, `cwd` where it is now; every session that ran there
    /// follows it.
    private func restRelocateSessions(_ call: RESTCall) -> HTTPResponse {
        guard let from = call.body.path, !from.isEmpty, let to = call.body.cwd, !to.isEmpty else {
            return HTTPResponse(400, "{\"error\":\"path and cwd required\"}")
        }
        guard HostFolders.exists(to) else { return HTTPResponse(400, Envelope.error("There is no folder at \(to)").encoded()) }
        let moved = relocate(from: from, to: to)
        var e = Envelope(type: "sessions")
        e.sessions = moved.map(\.info)
        return .json(e.encoded())
    }

    /// An agent on a linked computer asking about the sessions here.
    private func restLinkedAgent(_ call: RESTCall) -> HTTPResponse {
        return .json(linkedAgentReply(call.body).encoded())
    }

    /// This computer's connection code, for a client that holds
    /// several to link them (it is let in already, so the password
    /// the code carries is no news to it).
    private func restCode(_ call: RESTCall) -> HTTPResponse {
        guard let code = connectionCode else { return HTTPResponse(503, Envelope.error("No connection code yet").encoded()) }
        var e = Envelope(type: "code")
        e.text = code.encoded
        return .json(e.encoded())
    }

    /// The APNs key, set from this Mac (a tool, an agent) rather than
    /// in Settings: {"key": <the .p8's text>, "keyID": …, "teamID": …}.
    /// Written, never read back.
    private func restSetPushKey(_ call: RESTCall) -> HTTPResponse {
        let fields = parseJSON(call.request.body)
        if let problem = setAPNsKey(pem: fields?["key"].string ?? "", keyID: fields?["keyID"].string ?? "",
                                    teamID: fields?["teamID"].string ?? "") {
            return HTTPResponse(400, Envelope.error(problem).encoded())
        }
        return .json(Envelope(type: "push").encoded())
    }

    private func restTestPush(_ call: RESTCall) -> HTTPResponse {
        if let problem = sendTestPush() { return HTTPResponse(400, Envelope.error(problem).encoded()) }
        return .json(Envelope(type: "push").encoded())
    }

    /// A device that wants to hear, with the app closed, when a turn
    /// ends or an agent waits.
    private func restRegisterPushDevice(_ call: RESTCall) -> HTTPResponse {
        guard registerPush(call.body) else { return HTTPResponse(400, Envelope.error("A push token and its app are required").encoded()) }
        // Whether pushes will come: the device then leaves them to us.
        var reply = Envelope(type: "push")
        reply.exists = apnsKey.configured
        return .json(reply.encoded())
    }

    /// Forgets a peer, by its id or an address its code named (`text`).
    private func restUnlink(_ call: RESTCall) -> HTTPResponse {
        guard let key = call.body.text, !key.isEmpty else { return HTTPResponse(400, Envelope.error("The computer to forget is required").encoded()) }
        forget(peer: key)
        return .json(Envelope(type: "unlink").encoded())
    }

    /// A computer this one's code was pasted into, linking back: a peer.
    private func restLinkBack(_ call: RESTCall) -> HTTPResponse {
        guard let code = call.body.text.flatMap(ConnectionCode.init(parsing:)) else {
            return HTTPResponse(400, Envelope.error("A connection code is required").encoded())
        }
        adopt([code.peer], from: code.id.isEmpty ? nil : code.id)
        return .json(Envelope(type: "link").encoded())
    }

    /// The one call an agent can make to replace the server it runs
    /// under: `path` is the new bundle (omit it for a plain restart),
    /// `session` the session to carry on besides the busy ones.
    private func restRestart(_ call: RESTCall) -> HTTPResponse {
        var carry = sessions.filter(\.info.busy).map(\.info.id)
        if let named = call.body.session, !named.isEmpty, !carry.contains(named) { carry.append(named) }
        if let message = relaunch(installing: call.body.path, carrying: carry) {
            return HTTPResponse(400, Envelope.error(message).encoded())
        }
        var e = Envelope(type: "restart")
        e.sessions = sessions.filter { carry.contains($0.info.id) }.map(\.info)
        return .json(e.encoded())
    }

    /// Stops the server: the agents ended (what was running written down
    /// as running, so the next start carries it on), then the process —
    /// once the answer has gone out. How `visor-server stop` asks, which
    /// works the same on every system.
    private func restQuit(_ call: RESTCall) -> HTTPResponse {
        Self.log("asked to stop")
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            quit()
        }
        return .json(Envelope(type: "quit").encoded())
    }

    private func restStartSession(_ call: RESTCall) -> HTTPResponse {
        guard let agent = call.body.agent else { return HTTPResponse(400, "{\"error\":\"agent required\"}") }
        var e = Envelope(type: "start")
        e.id = call.body.id; e.agent = agent; e.cwd = call.body.cwd; e.title = call.body.title; e.skipPermissions = call.body.skipPermissions; e.resume = call.body.resume
        e.mode = call.body.mode
        perform(e, from: nil)
        let created = session(e.id) ?? sessions.last
        return .json(created.map { Envelope.sessions([$0.info]).encoded() } ?? "{}")
    }

    private func restEndSession(_ call: RESTCall) -> HTTPResponse {
        var e = Envelope(type: "end"); e.session = call.parts[1]
        guard session(e.session) != nil else { return HTTPResponse(404, "{\"error\":\"no such session\"}") }
        perform(e, from: nil)
        return .json(sessionsJSON())
    }

    private func restSessionAction(_ call: RESTCall) -> HTTPResponse {
        let action = call.parts[2]
        guard ["send", "stop", "unqueue", "archive", "unarchive", "permissions", "settings", "approve", "rename", "mode", "acknowledge"].contains(action) else {
            return HTTPResponse(404, "{\"error\":\"unknown action\"}")
        }
        guard let record = session(call.parts[1]) else { return HTTPResponse(404, "{\"error\":\"no such session\"}") }
        var e = call.body
        e.type = action
        e.session = record.info.id
        perform(e, from: nil)
        return .json(Envelope.sessions([record.info]).encoded())
    }

    /// The path below `/api`, wherever a front mounted it: most forward
    /// `/api/...` as it is; a reverse proxy may forward `/visor/api/...`
    /// whole, which reads the same.
    static func apiPath(_ path: String) -> String {
        if let range = path.range(of: "/api/") { return "/" + path[range.upperBound...] }
        if path == "/api" || path.hasSuffix("/api") { return "/" }
        return path
    }

    /// A request's query string, decoded.
    static func query(_ path: String) -> [String: String] {
        guard let q = path.split(separator: "?", maxSplits: 1).dropFirst().first else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = kv.first?.removingPercentEncoding else { continue }
            out[key] = kv.count > 1 ? (kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1]) : ""
        }
        return out
    }
}
