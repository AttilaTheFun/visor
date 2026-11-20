extension SuperCompactStatus {
    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "type": .string("superCompact"), "id": .string(id), "session": .string(session), "title": .string(title),
            "phase": .string(phase.rawValue), "chunk": .number(Double(chunk)), "chunks": .number(Double(chunks)),
            "mergeStep": .number(Double(mergeStep)), "mergeSteps": .number(Double(mergeSteps)),
            "warnings": .array(warnings.map(JSONValue.string)), "started": .number(started), "updated": .number(updated),
        ]
        if let failedIn { o["failedIn"] = .string(failedIn.rawValue) }
        if let error { o["error"] = .string(error) }
        if let handoff { o["handoff"] = .string(handoff) }
        if let continuedAs { o["continuedAs"] = .string(continuedAs) }
        if discarded { o["discarded"] = .bool(true) }
        if let finished { o["finished"] = .number(finished) }
        return .object(o)
    }

    /// As the server answers it (its SuperCompactJob, encoded): nil for
    /// anything else. A `discarded` time, as the server keeps it, or a
    /// bool, is discarded.
    public init?(json: JSONValue) {
        guard let id = json["id"].string, let session = json["session"].string,
              let phase = json["phase"].string.flatMap(Phase.init(rawValue:)) else { return nil }
        self.init(id: id, session: session, title: json["title"].string ?? "", phase: phase,
                  failedIn: json["failedIn"].string.flatMap(Phase.init(rawValue:)), chunk: json["chunk"].int ?? 0,
                  chunks: json["chunks"].int ?? 0, mergeStep: json["mergeStep"].int ?? 0, mergeSteps: json["mergeSteps"].int ?? 0,
                  error: json["error"].string, warnings: json["warnings"].array?.compactMap(\.string) ?? [], handoff: json["handoff"].string,
                  continuedAs: json["continuedAs"].string, discarded: json["discarded"].bool ?? (json["discarded"].double != nil),
                  started: json["started"].double ?? 0, updated: json["updated"].double, finished: json["finished"].double)
    }
}
