import Foundation

extension QueueEntry {
    public var json: JSONValue {
        var object: [String: JSONValue] = ["id": .string(id), "agent": .string(agent.rawValue), "title": .string(title),
                                           "labels": .array(labels.map(JSONValue.string)), "links": .array(links.map(JSONValue.string)),
                                           "archiveWhen": .string(archiveWhen.rawValue), "createdBy": .string(createdBy),
                                           "created": .number(created.timeIntervalSince1970), "state": .string(state.rawValue)]
        for (key, value) in [("prompt", prompt), ("repository", repository), ("branch", branch), ("cwd", cwd), ("runner", runner),
                             ("problem", problem)] {
            if let value { object[key] = .string(value) }
        }
        return .object(object)
    }

    /// Nil for one missing what it must say. A state or archive rule this
    /// build doesn't know reads as waiting, and as never.
    public init?(json: JSONValue) {
        guard let id = json["id"].string, !id.isEmpty, let agent = json["agent"].string.flatMap(AgentKind.init(rawValue:)),
              let createdBy = json["createdBy"].string, let created = json["created"].double else { return nil }
        self.init(id: id, agent: agent, title: json["title"].string ?? "", prompt: json["prompt"].string,
                  repository: json["repository"].string, branch: json["branch"].string, cwd: json["cwd"].string,
                  runner: json["runner"].string, labels: (json["labels"].array ?? []).compactMap(\.string),
                  links: (json["links"].array ?? []).compactMap(\.string),
                  archiveWhen: json["archiveWhen"].string.flatMap(ArchiveWhen.init(rawValue:)) ?? .never,
                  createdBy: createdBy, created: Date(timeIntervalSince1970: created),
                  state: json["state"].string.flatMap(State.init(rawValue:)) ?? .waiting, problem: json["problem"].string)
    }
}
