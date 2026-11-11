extension AgentHello {
    public var json: JSONValue {
        .object(["type": .string("agent"), "session": .string(session), "agent": .string(agent.rawValue), "cwd": .string(cwd),
                 "title": .string(title), "runner": .string(runner), "links": .array(links.map(JSONValue.string)),
                 "place": .string(place.rawValue)])
    }

    /// Nil for anything but an agent's hello, or one missing what it must say.
    public init?(json: JSONValue) {
        guard json["type"].string == "agent", let session = json["session"].string, !session.isEmpty,
              let agent = json["agent"].string.flatMap(AgentKind.init(rawValue:)), let cwd = json["cwd"].string,
              let runner = json["runner"].string, let place = json["place"].string.flatMap(AgentPlace.init(rawValue:)) else { return nil }
        self.init(session: session, agent: agent, cwd: cwd, title: json["title"].string ?? "", runner: runner,
                  links: (json["links"].array ?? []).compactMap(\.string), place: place)
    }
}
