extension MigrationOffer {
    public var json: JSONValue {
        .object(["token": .string(token), "from": .string(from), "session": session.json, "resumeID": .string(resumeID), "home": .string(home),
                 "files": .array(files.map(\.json))])
    }

    /// An offer as JSON has it. A server before 0.61 also listed the
    /// session's `projects`, which are passed over.
    public init?(json: JSONValue) {
        guard let token = json["token"].string, let session = SessionInfo(json: json["session"]),
              let resumeID = json["resumeID"].string, let home = json["home"].string else { return nil }
        self.init(token: token, from: json["from"].string ?? "", session: session, resumeID: resumeID, home: home,
                  files: (json["files"].array ?? []).compactMap(MigrationFile.init(json:)))
    }
}
