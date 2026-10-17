// As Claude Code gives a question (AskUserQuestion's input), so the agent's
// own words pass through unchanged.

extension AgentQuestion {
    var json: JSONValue {
        .object(["question": .string(question), "header": .string(header), "options": .array(options.map(\.json)),
                 "multiSelect": .bool(multiSelect)])
    }

    init?(json: JSONValue) {
        guard let question = json["question"].string else { return nil }
        self.init(question: question, header: json["header"].string ?? "",
                  options: json["options"].array?.compactMap(Option.init(json:)) ?? [], multiSelect: json["multiSelect"].bool ?? false)
    }
}

extension AgentQuestion.Option {
    var json: JSONValue { .object(["label": .string(label), "description": .string(description)]) }

    init?(json: JSONValue) {
        guard let label = json["label"].string else { return nil }
        self.init(label: label, description: json["description"].string ?? "")
    }
}
