// The wire encoding, by hand over the protocol's JSONValue: Foundation's
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
        e.resources = ServerResources(json: value["resources"])
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
        e.client = value["client"].string
        e.notice = value["notice"].string
        e.data = value["data"].string
        e.rows = value["rows"].int
        e.before = value["before"].string
        e.more = value["more"].bool
        e.revision = value["revision"].int
        e.generation = value["generation"].int
        e.after = value["after"].array?.compactMap(\.string)
        e.removed = value["removed"].array?.compactMap(\.string)
        e.reset = value["reset"].bool
        e.later = value["later"].bool
        e.follows = value["follows"].string
        e.signIn = value["signIn"].string
        e.questions = value["questions"].array?.compactMap(AgentQuestion.init(json:))
        if case .object(let map) = value["answers"] { e.answers = map.compactMapValues(\.string) }
        e.status = value["status"].array?.compactMap(StatusItem.init(json:))
        e.streams = value["streams"].array?.compactMap { item in
            guard let id = item["id"].string, let text = item["text"].string else { return nil }
            return StreamChunk(id: id, text: text)
        }
        e.images = value["images"].array?.compactMap(\.string)
        e.folders = value["folders"].array?.compactMap(\.string)
        e.addresses = value["addresses"].array?.compactMap(\.string)
        e.server = value["server"].string
        e.messageID = value["messageID"].string
        e.report = DirectoryReport(json: value["report"])
        e.relayed = value["relayed"].array?.compactMap(RelayMessage.init(json:))
        e.receipt = RelayReceipt(json: value["receipt"])
        e.codes = ConnectionCodes(json: value["codes"])
        e.standalone = value["standalone"].bool
        e.container = value["container"].bool
        e.resumable = value["resumable"].array?.compactMap(ResumableSession.init(json:))
        e.deviceToken = value["deviceToken"].string
        e.platform = value["platform"].string
        e.pushEnvironment = value["pushEnvironment"].string
        e.pushTopic = value["pushTopic"].string
        e.version = value["version"].string
        e.migration = value["migration"].string
        e.offer = MigrationOffer(json: value["offer"])
        e.plan = MigrationPlan(json: value["plan"])
        e.steps = value["steps"].array?.compactMap(MigrationStep.init(json:))
        e.file = MigrationFile(json: value["file"])
        e.offset = value["offset"].int
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
        if let resources { o["resources"] = resources.json }
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
        put("client", client)
        put("notice", notice)
        if let rows { o["rows"] = .number(Double(rows)) }
        put("before", before)
        putBool("more", more)
        if let revision { o["revision"] = .number(Double(revision)) }
        if let generation { o["generation"] = .number(Double(generation)) }
        if let after { o["after"] = .array(after.map(JSONValue.string)) }
        if let removed, !removed.isEmpty { o["removed"] = .array(removed.map(JSONValue.string)) }
        putBool("reset", reset)
        putBool("later", later)
        put("follows", follows)
        put("signIn", signIn)
        if let questions { o["questions"] = .array(questions.map(\.json)) }
        if let answers { o["answers"] = .object(answers.mapValues(JSONValue.string)) }
        if let status { o["status"] = .array(status.map(\.json)) }
        if let streams { o["streams"] = .array(streams.map { .object(["id": .string($0.id), "text": .string($0.text)]) }) }
        if let images, !images.isEmpty { o["images"] = .array(images.map(JSONValue.string)) }
        if let folders { o["folders"] = .array(folders.map(JSONValue.string)) }
        if let addresses { o["addresses"] = .array(addresses.map(JSONValue.string)) }
        put("server", server); put("messageID", messageID)
        if let report { o["report"] = report.json }
        if let relayed { o["relayed"] = .array(relayed.map(\.json)) }
        if let receipt { o["receipt"] = receipt.json }
        if let codes { o["codes"] = codes.json }
        putBool("standalone", standalone)
        putBool("container", container)
        if let resumable { o["resumable"] = .array(resumable.map(\.json)) }
        if let deviceToken { o["deviceToken"] = .string(deviceToken) }
        if let platform { o["platform"] = .string(platform) }
        if let pushEnvironment { o["pushEnvironment"] = .string(pushEnvironment) }
        if let pushTopic { o["pushTopic"] = .string(pushTopic) }
        if let version { o["version"] = .string(version) }
        if let migration { o["migration"] = .string(migration) }
        if let offer { o["offer"] = offer.json }
        if let plan { o["plan"] = plan.json }
        if let steps { o["steps"] = .array(steps.map(\.json)) }
        if let file { o["file"] = file.json }
        if let offset { o["offset"] = .number(Double(offset)) }
        if let commands {
            o["commands"] = .array(commands.map { .object(["name": .string($0.name), "description": .string($0.description), "argumentHint": .string($0.argumentHint)]) })
        }
        return .object(o)
    }
}
