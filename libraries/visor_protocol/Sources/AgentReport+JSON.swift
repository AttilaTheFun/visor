import Foundation

extension AgentReport {
    public var json: JSONValue {
        var object: [String: JSONValue] = ["type": .string("report"), "session": .string(session), "kind": .string(kind.rawValue),
                                           "summary": .string(summary), "at": .number(at.timeIntervalSince1970)]
        if let step { object["step"] = .string(step) }
        if let pullRequest { object["pullRequest"] = .string(pullRequest) }
        if let merged { object["merged"] = .bool(merged) }
        if let reason { object["reason"] = .string(reason.rawValue) }
        return .object(object)
    }

    /// Nil for anything but a report, or one of a kind this build doesn't
    /// know. A blocked report's reason this build doesn't know is left out.
    public init?(json: JSONValue) {
        guard json["type"].string == "report", let session = json["session"].string, !session.isEmpty,
              let kind = json["kind"].string.flatMap(Kind.init(rawValue:)), let at = json["at"].double else { return nil }
        self.init(session: session, kind: kind, summary: json["summary"].string ?? "", step: json["step"].string,
                  pullRequest: json["pullRequest"].string, merged: json["merged"].bool,
                  reason: json["reason"].string.flatMap(Reason.init(rawValue:)), at: Date(timeIntervalSince1970: at))
    }
}
