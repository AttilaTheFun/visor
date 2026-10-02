extension ApprovalRequest {
    var json: JSONValue {
        .object(["id": .string(id), "tool": .string(tool), "summary": .string(summary)])
    }

    init?(json: JSONValue) {
        guard let id = json["id"].string, let tool = json["tool"].string else { return nil }
        self.init(id: id, tool: tool, summary: json["summary"].string ?? "")
    }
}
