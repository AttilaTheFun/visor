extension RunnerStart {
    public var json: JSONValue {
        var object: [String: JSONValue] = ["type": .string("start"), "session": .string(session), "agentToken": .string(agentToken),
                                           "agent": .string(agent.rawValue), "title": .string(title),
                                           "links": .array(links.map(JSONValue.string))]
        for (key, value) in [("repository", repository), ("branch", branch), ("cwd", cwd), ("prompt", prompt), ("resume", resume)] {
            if let value { object[key] = .string(value) }
        }
        return .object(object)
    }

    public init?(json: JSONValue) {
        guard json["type"].string == "start", let session = json["session"].string, !session.isEmpty,
              let token = json["agentToken"].string, let agent = json["agent"].string.flatMap(AgentKind.init(rawValue:)) else { return nil }
        self.init(session: session, agentToken: token, agent: agent, repository: json["repository"].string, branch: json["branch"].string,
                  cwd: json["cwd"].string, prompt: json["prompt"].string, title: json["title"].string ?? "",
                  links: (json["links"].array ?? []).compactMap(\.string), resume: json["resume"].string)
    }
}
