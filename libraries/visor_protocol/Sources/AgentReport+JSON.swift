import Foundation

extension AgentReport {
    public var json: JSONValue {
        var object: [String: JSONValue] = ["type": .string("report"), "session": .string(session), "kind": .string(kind.rawValue),
                                           "text": .string(text), "at": .number(at.timeIntervalSince1970)]
        if let pullRequest { object["pullRequest"] = .string(pullRequest) }
        return .object(object)
    }

    public init?(json: JSONValue) {
        guard json["type"].string == "report", let session = json["session"].string, !session.isEmpty,
              let kind = json["kind"].string.flatMap(Kind.init(rawValue:)), let at = json["at"].double else { return nil }
        self.init(session: session, kind: kind, text: json["text"].string ?? "", pullRequest: json["pullRequest"].string,
                  at: Date(timeIntervalSince1970: at))
    }
}
