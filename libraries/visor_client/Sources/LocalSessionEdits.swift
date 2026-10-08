import VisorProtocol

/// What the user did to sessions of a server that keeps no titles, archive
/// or ending of its own (`AgentServer.managesSessions` false): renamed,
/// archived and removed here, kept on this device for its record, and
/// laid over every list the server sends.
struct LocalSessionEdits: Equatable {
    var titles: [String: String] = [:]
    var archived: Set<String> = []
    var removed: Set<String> = []

    /// The server's list as the user left it.
    func apply(to sessions: [SessionInfo]) -> [SessionInfo] {
        sessions.filter { !removed.contains($0.id) }.map { info in
            var info = info
            if let title = titles[info.id] { info.title = title }
            info.archived = archived.contains(info.id)
            return info
        }
    }

    var json: JSONValue {
        .object(["titles": .object(titles.mapValues(JSONValue.string)),
                 "archived": .array(archived.sorted().map(JSONValue.string)),
                 "removed": .array(removed.sorted().map(JSONValue.string))])
    }

    init() {}

    init(json: JSONValue) {
        for (id, title) in json["titles"].object ?? [:] { if let title = title.string { titles[id] = title } }
        archived = Set(json["archived"].array?.compactMap(\.string) ?? [])
        removed = Set(json["removed"].array?.compactMap(\.string) ?? [])
    }
}
