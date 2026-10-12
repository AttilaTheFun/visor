extension MigrationOffer {
    public var json: JSONValue {
        .object(["token": .string(token), "from": .string(from), "session": session.json, "resumeID": .string(resumeID), "home": .string(home),
                 "files": .array(files.map(\.json)), "projects": .array(projects.map(\.json))])
    }

    public init?(json: JSONValue) {
        guard let token = json["token"].string, let session = SessionInfo(json: json["session"]),
              let resumeID = json["resumeID"].string, let home = json["home"].string else { return nil }
        self.init(token: token, from: json["from"].string ?? "", session: session, resumeID: resumeID, home: home,
                  files: (json["files"].array ?? []).compactMap(MigrationFile.init(json:)),
                  projects: (json["projects"].array ?? []).compactMap(MigrationProject.init(json:)))
    }
}
