extension MigrationProject {
    public var json: JSONValue {
        var o: [String: JSONValue] = ["path": .string(path), "unshared": .bool(unshared), "size": .number(Double(size)),
                                      "mentions": .number(Double(mentions))]
        if let remote { o["remote"] = .string(remote) }
        if let branch { o["branch"] = .string(branch) }
        if let commit { o["commit"] = .string(commit) }
        return .object(o)
    }

    public init?(json: JSONValue) {
        guard let path = json["path"].string, !path.isEmpty else { return nil }
        self.init(path: path, remote: json["remote"].string, branch: json["branch"].string, commit: json["commit"].string,
                  unshared: json["unshared"].bool ?? false, size: json["size"].int ?? 0, mentions: json["mentions"].int ?? 0)
    }
}
