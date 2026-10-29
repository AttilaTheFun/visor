extension SideQuestion {
    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "question": .string(question), "asked": .number(asked)]
        if let answer { o["answer"] = .string(answer) }
        if let failure { o["failure"] = .string(failure) }
        return .object(o)
    }

    init?(json: JSONValue) {
        guard let id = json["id"].string, let question = json["question"].string else { return nil }
        self.init(id: id, question: question, answer: json["answer"].string, failure: json["failure"].string,
                  asked: json["asked"].double ?? 0)
    }
}
