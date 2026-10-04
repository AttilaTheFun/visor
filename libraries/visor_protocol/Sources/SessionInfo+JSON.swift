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
        if let usage { o["usage"] = usage.json }
        if let goal { o["goal"] = .string(goal) }
        if let loopWake { o["loopWake"] = .number(loopWake) }
        if let loopCron { o["loopCron"] = .string(loopCron) }
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
        usage = SessionUsage(json: json["usage"])
        goal = json["goal"].string
        loopWake = json["loopWake"].double
        loopCron = json["loopCron"].string
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
