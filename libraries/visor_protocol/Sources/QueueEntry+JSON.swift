import Foundation

extension QueueEntry {
    public var json: JSONValue {
        var object: [String: JSONValue] = ["id": .string(id), "kind": .string(kind.rawValue), "session": .string(session),
                                           "agent": .string(agent.rawValue), "title": .string(title),
                                           "labels": .array(labels.map(JSONValue.string)), "links": .array(links.map(JSONValue.string)),
                                           "archiveWhen": .string(archiveWhen.rawValue), "createdBy": .string(createdBy),
                                           "created": .number(created.timeIntervalSince1970), "state": .string(state.rawValue)]
        for (key, value) in [("prompt", prompt), ("repository", repository), ("branch", branch), ("cwd", cwd), ("resume", resume),
                             ("copyFrom", copyFrom), ("runner", runner), ("claimedBy", claimedBy), ("problem", problem)] {
            if let value { object[key] = .string(value) }
        }
        if let leaseExpires { object["leaseExpires"] = .number(leaseExpires.timeIntervalSince1970) }
        return .object(object)
    }

    /// Nil for one missing what it must say, or of a kind this build doesn't
    /// know (it can't be carried out). A state or archive rule this build
    /// doesn't know reads as waiting, and as never.
    public init?(json: JSONValue) {
        guard let id = json["id"].string, !id.isEmpty, let session = json["session"].string, !session.isEmpty,
              let kind = Kind(rawValue: json["kind"].string ?? Kind.start.rawValue),
              let agent = json["agent"].string.flatMap(AgentKind.init(rawValue:)),
              let createdBy = json["createdBy"].string, let created = json["created"].double else { return nil }
        self.init(id: id, kind: kind, session: session, agent: agent, title: json["title"].string ?? "", prompt: json["prompt"].string,
                  repository: json["repository"].string, branch: json["branch"].string, cwd: json["cwd"].string,
                  resume: json["resume"].string, copyFrom: json["copyFrom"].string, runner: json["runner"].string,
                  labels: (json["labels"].array ?? []).compactMap(\.string), links: (json["links"].array ?? []).compactMap(\.string),
                  archiveWhen: json["archiveWhen"].string.flatMap(ArchiveWhen.init(rawValue:)) ?? .never,
                  createdBy: createdBy, created: Date(timeIntervalSince1970: created),
                  state: json["state"].string.flatMap(State.init(rawValue:)) ?? .waiting, claimedBy: json["claimedBy"].string,
                  leaseExpires: json["leaseExpires"].double.map(Date.init(timeIntervalSince1970:)), problem: json["problem"].string)
    }
}
