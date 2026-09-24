// The wire encoding, by hand over universal_ui's JSONValue: Foundation's
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
        e.revision = value["revision"].double.map(Int.init)
        e.generation = value["generation"].double.map(Int.init)
        e.status = value["status"].array?.compactMap(StatusItem.init(json:))
        e.streams = value["streams"].array?.compactMap { item in
            guard let id = item["id"].string, let text = item["text"].string else { return nil }
            return StreamChunk(id: id, text: text)
        }
        e.images = value["images"].array?.compactMap(\.string)
        e.folders = value["folders"].array?.compactMap(\.string)
        e.resumable = value["resumable"].array?.compactMap(ResumableSession.init(json:))
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
        if let status { o["status"] = .array(status.map(\.json)) }
        if let streams { o["streams"] = .array(streams.map { .object(["id": .string($0.id), "text": .string($0.text)]) }) }
        if let images, !images.isEmpty { o["images"] = .array(images.map(JSONValue.string)) }
        if let folders { o["folders"] = .array(folders.map(JSONValue.string)) }
        if let resumable { o["resumable"] = .array(resumable.map(\.json)) }
        return .object(o)
    }
}

extension SessionInfo {
    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "agent": .string(agent.rawValue), "cwd": .string(cwd), "title": .string(title),
            "busy": .bool(busy), "ended": .bool(ended), "skipPermissions": .bool(skipPermissions),
            "archived": .bool(archived), "created": .number(created),
        ]
        if let pendingApproval { o["pendingApproval"] = pendingApproval.json }
        if let resumeCommand { o["resumeCommand"] = .string(resumeCommand) }
        if let model { o["model"] = .string(model) }
        if let effort { o["effort"] = .string(effort) }
        if let reportedModel { o["reportedModel"] = .string(reportedModel) }
        if let contextUsed { o["contextUsed"] = .number(Double(contextUsed)) }
        if !queued.isEmpty { o["queued"] = .array(queued.map(JSONValue.string)) }
        if let contextLimit { o["contextLimit"] = .number(Double(contextLimit)) }
        if let preview { o["preview"] = .string(preview) }
        if let updated { o["updated"] = .number(updated) }
        if case .tui(let controller, let cols, let rows) = mode {
            o["mode"] = .object(["kind": .string("tui"), "controller": .string(controller),
                                 "cols": .number(Double(cols)), "rows": .number(Double(rows))])
        }
        return .object(o)
    }

    public init?(json: JSONValue) {
        guard let id = json["id"].string, let agent = json["agent"].string.flatMap(AgentKind.init(wire:)),
              let cwd = json["cwd"].string, let title = json["title"].string else { return nil }
        self.init(id: id, agent: agent, cwd: cwd, title: title, busy: json["busy"].bool ?? false,
                  ended: json["ended"].bool ?? false, skipPermissions: json["skipPermissions"].bool ?? true,
                  archived: json["archived"].bool ?? false, resumeCommand: json["resumeCommand"].string,
                  model: json["model"].string, effort: json["effort"].string, created: json["created"].double ?? 0)
        pendingApproval = ApprovalRequest(json: json["pendingApproval"])
        contextUsed = json["contextUsed"].double.map(Int.init)
        reportedModel = json["reportedModel"].string
        queued = json["queued"].array?.compactMap(\.string) ?? []
        contextLimit = json["contextLimit"].double.map(Int.init)
        preview = json["preview"].string
        updated = json["updated"].double
        if json["mode"]["kind"].string == "tui", let controller = json["mode"]["controller"].string,
           let cols = json["mode"]["cols"].double, let rows = json["mode"]["rows"].double {
            mode = .tui(controller: controller, cols: Int(cols), rows: Int(rows))
        } else {
            mode = .chat
        }
    }
}

extension StatusItem {
    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "kind": .string(kind.rawValue), "label": .string(label), "running": .bool(running)]
        if !tasks.isEmpty { o["tasks"] = .array(tasks.map { .object(["title": .string($0.title), "state": .string($0.state.rawValue)]) }) }
        return .object(o)
    }

    init?(json: JSONValue) {
        guard let id = json["id"].string, let kind = json["kind"].string.flatMap(Kind.init(rawValue:)), let label = json["label"].string else { return nil }
        let tasks = json["tasks"].array?.compactMap { task -> TaskItem? in
            guard let title = task["title"].string, let state = task["state"].string.flatMap(TaskItem.State.init(rawValue:)) else { return nil }
            return TaskItem(title: title, state: state)
        } ?? []
        self.init(id: id, kind: kind, label: label, running: json["running"].bool ?? false, tasks: tasks)
    }
}

extension TranscriptEntry {
    /// The row as JSON — what a cache keeps and what goes over the wire.
    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "role": .string(role.rawValue), "text": .string(text),
            "activities": .array(activities.map(JSONValue.string)),
        ]
        if let toolName { o["toolName"] = .string(toolName) }
        if !images.isEmpty { o["images"] = .array(images.map(JSONValue.string)) }
        if !imageSizes.isEmpty {
            o["imageSizes"] = .array(imageSizes.map { .object(["width": .number(Double($0.width)), "height": .number(Double($0.height))]) })
        }
        return .object(o)
    }

    public init?(json: JSONValue) {
        guard let id = json["id"].string, let role = json["role"].string.flatMap(Role.init(rawValue:)),
              let text = json["text"].string else { return nil }
        self.init(id: id, role: role, text: text, activities: json["activities"].array?.compactMap(\.string) ?? [],
                  toolName: json["toolName"].string,
                  images: json["images"].array?.compactMap(\.string) ?? [],
                  imageSizes: json["imageSizes"].array?.compactMap { size -> ImageSize? in
                      guard let w = size["width"].double, let h = size["height"].double, w > 0, h > 0 else { return nil }
                      return ImageSize(width: Int(w), height: Int(h))
                  } ?? [])
    }
}

extension ApprovalRequest {
    var json: JSONValue {
        .object(["id": .string(id), "tool": .string(tool), "summary": .string(summary)])
    }

    init?(json: JSONValue) {
        guard let id = json["id"].string, let tool = json["tool"].string else { return nil }
        self.init(id: id, tool: tool, summary: json["summary"].string ?? "")
    }
}

extension AgentModel {
    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "title": .string(title), "efforts": .array(efforts.map(JSONValue.string))]
        if let subtitle { o["subtitle"] = .string(subtitle) }
        if let defaultEffort { o["defaultEffort"] = .string(defaultEffort) }
        if let group { o["group"] = .string(group) }
        if !listed { o["listed"] = .bool(false) }
        return .object(o)
    }

    init?(json: JSONValue) {
        guard let id = json["id"].string, let title = json["title"].string else { return nil }
        self.init(id: id, title: title, subtitle: json["subtitle"].string,
                  efforts: json["efforts"].array?.compactMap(\.string) ?? [], defaultEffort: json["defaultEffort"].string,
                  group: json["group"].string, listed: json["listed"].bool ?? true)
    }
}

extension AgentCatalog {
    var json: JSONValue {
        var o: [String: JSONValue] = ["agent": .string(agent.rawValue), "models": .array(models.map(\.json)), "available": .bool(available)]
        if let defaultModel { o["defaultModel"] = .string(defaultModel) }
        return .object(o)
    }

    init?(json: JSONValue) {
        guard let agent = json["agent"].string.flatMap(AgentKind.init(wire:)) else { return nil }
        self.init(agent: agent, models: json["models"].array?.compactMap(AgentModel.init(json:)) ?? [],
                  defaultModel: json["defaultModel"].string, available: json["available"].bool ?? true)
    }
}

extension ResumableSession {
    var json: JSONValue {
        .object(["id": .string(id), "agent": .string(agent.rawValue), "cwd": .string(cwd), "title": .string(title), "timestamp": .number(timestamp)])
    }

    public init?(json: JSONValue) {
        guard let id = json["id"].string, let agent = json["agent"].string.flatMap(AgentKind.init(wire:)) else { return nil }
        self.init(id: id, agent: agent, cwd: json["cwd"].string ?? "", title: json["title"].string ?? "", timestamp: json["timestamp"].double ?? 0)
    }
}
