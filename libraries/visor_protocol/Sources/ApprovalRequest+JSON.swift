extension ApprovalRequest {
    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "tool": .string(tool), "summary": .string(summary)]
        if let questions, !questions.isEmpty { o["questions"] = .array(questions.map(\.json)) }
        return .object(o)
    }

    init?(json: JSONValue) {
        guard let id = json["id"].string, let tool = json["tool"].string else { return nil }
        let questions = json["questions"].array?.compactMap(AgentQuestion.init(json:))
        self.init(id: id, tool: tool, summary: json["summary"].string ?? "", questions: questions?.isEmpty == false ? questions : nil)
    }
}
