// The wire encoding, by hand over Isomer's JSONValue: Foundation's
// JSONEncoder is not on the portable stack (wasm, Android), and the same
// bytes must come out of every host. Optional fields are omitted when nil.

extension Envelope {
    public func encoded() -> String { json.encoded() }

    /// A REST body: the same fields, `type` optional (the route names it).
    public static func decodeBody(_ text: String) -> Envelope {
        decode(text, defaultType: "body") ?? Envelope(type: "body")
    }

    public static func decode(_ text: String, defaultType: String? = nil) -> Envelope? {
        guard let value = parseJSON(text), let type = value["type"].string ?? defaultType else { return nil }
        var e = Envelope(type: type)
        e.password = value["password"].string
        e.host = value["host"].string
        e.login = value["login"].string
        e.message = value["message"].string
        e.id = value["id"].string
        e.agent = value["agent"].string.flatMap(AgentKind.init(wire:))
        e.cwd = value["cwd"].string
        e.title = value["title"].string
        e.skipPermissions = value["skipPermissions"].bool
        e.session = value["session"].string
        e.text = value["text"].string
        e.sessions = value["sessions"].array?.compactMap(SessionInfo.init(json:))
        e.catalogs = value["catalogs"].array?.compactMap(AgentCatalog.init(json:))
        e.account = AgentAccount(json: value["account"])
        e.model = value["model"].string
        e.effort = value["effort"].string
        e.entries = value["entries"].array?.compactMap(TranscriptEntry.init(json:))
        e.streaming = value["streaming"].string
        e.activity = value["activity"].string
        e.busy = value["busy"].bool
        e.error = value["error"].string
        e.entry = TranscriptEntry(json: value["entry"])
        e.approval = ApprovalRequest(json: value["approval"])
        e.allow = value["allow"].bool
        e.token = value["token"].string
        e.prompt = value["prompt"].string
        e.resume = value["resume"].string
        e.path = value["path"].string
        e.exists = value["exists"].bool
        e.mode = value["mode"].string
        e.controller = value["controller"].string
        e.client = value["client"].string
        e.notice = value["notice"].string
        e.data = value["data"].string
        e.cols = value["cols"].int
        e.rows = value["rows"].int
        e.before = value["before"].string
        e.more = value["more"].bool
        e.revision = value["revision"].int
        e.generation = value["generation"].int
        e.after = value["after"].array?.compactMap(\.string)
        e.removed = value["removed"].array?.compactMap(\.string)
        e.reset = value["reset"].bool
        e.status = value["status"].array?.compactMap(StatusItem.init(json:))
        e.streams = value["streams"].array?.compactMap { item in
            guard let id = item["id"].string, let text = item["text"].string else { return nil }
            return StreamChunk(id: id, text: text)
        }
        e.images = value["images"].array?.compactMap(\.string)
        e.folders = value["folders"].array?.compactMap(\.string)
        e.addresses = value["addresses"].array?.compactMap(\.string)
        e.peers = value["peers"].array?.compactMap(Peer.init(json:))
        e.sshKey = value["sshKey"].string
        e.standalone = value["standalone"].bool
        e.resumable = value["resumable"].array?.compactMap(ResumableSession.init(json:))
        e.deviceToken = value["deviceToken"].string
        e.platform = value["platform"].string
        e.pushEnvironment = value["pushEnvironment"].string
        e.pushTopic = value["pushTopic"].string
        e.commands = value["commands"].array?.compactMap { item in
            item["name"].string.map { SlashCommand(name: $0, description: item["description"].string ?? "", argumentHint: item["argumentHint"].string ?? "") }
        }
        return e
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["type": .string(type)]
        func put(_ key: String, _ s: String?) { if let s { o[key] = .string(s) } }
        func putBool(_ key: String, _ b: Bool?) { if let b { o[key] = .bool(b) } }
        put("password", password); put("host", host); put("login", login); put("message", message); put("id", id)
        put("agent", agent?.rawValue); put("cwd", cwd); put("title", title)
        putBool("skipPermissions", skipPermissions)
        put("session", session); put("text", text)
        if let sessions { o["sessions"] = .array(sessions.map(\.json)) }
        if let catalogs { o["catalogs"] = .array(catalogs.map(\.json)) }
        if let account { o["account"] = account.json }
        put("model", model); put("effort", effort)
        if let entries { o["entries"] = .array(entries.map(\.json)) }
        put("streaming", streaming); put("activity", activity)
        putBool("busy", busy)
        put("error", error)
        if let entry { o["entry"] = entry.json }
        if let approval { o["approval"] = approval.json }
        putBool("allow", allow)
        put("token", token); put("prompt", prompt); put("resume", resume); put("path", path)
        putBool("exists", exists)
        put("mode", mode); put("data", data)
        put("controller", controller); put("client", client)
        put("notice", notice)
        if let cols { o["cols"] = .number(Double(cols)) }
        if let rows { o["rows"] = .number(Double(rows)) }
        put("before", before)
        putBool("more", more)
        if let revision { o["revision"] = .number(Double(revision)) }
        if let generation { o["generation"] = .number(Double(generation)) }
        if let after { o["after"] = .array(after.map(JSONValue.string)) }
        if let removed, !removed.isEmpty { o["removed"] = .array(removed.map(JSONValue.string)) }
        putBool("reset", reset)
        if let status { o["status"] = .array(status.map(\.json)) }
        if let streams { o["streams"] = .array(streams.map { .object(["id": .string($0.id), "text": .string($0.text)]) }) }
        if let images, !images.isEmpty { o["images"] = .array(images.map(JSONValue.string)) }
        if let folders { o["folders"] = .array(folders.map(JSONValue.string)) }
        if let addresses { o["addresses"] = .array(addresses.map(JSONValue.string)) }
        if let peers { o["peers"] = .array(peers.map(\.json)) }
        put("sshKey", sshKey)
        putBool("standalone", standalone)
        if let resumable { o["resumable"] = .array(resumable.map(\.json)) }
        if let deviceToken { o["deviceToken"] = .string(deviceToken) }
        if let platform { o["platform"] = .string(platform) }
        if let pushEnvironment { o["pushEnvironment"] = .string(pushEnvironment) }
        if let pushTopic { o["pushTopic"] = .string(pushTopic) }
        if let commands {
            o["commands"] = .array(commands.map { .object(["name": .string($0.name), "description": .string($0.description), "argumentHint": .string($0.argumentHint)]) })
        }
        return .object(o)
    }
}
