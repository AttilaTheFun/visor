import VisorProtocol
import VisorServices

/// What the home screen's widget shows, as the JSON it reads: up to eight
/// live sessions, the latest first — what each is called, where, its
/// latest words and whether it is working, waiting for approval or working
/// toward a goal. Made from the sessions the client holds, and brought up
/// to date by a push when the app is not running to hold them.
public enum WidgetSessions {
    /// A session and the server it is on.
    public struct Source {
        public var computer: String
        public var address: String
        public var info: SessionInfo
        public init(computer: String, address: String, info: SessionInfo) {
            self.computer = computer
            self.address = address
            self.info = info
        }
    }

    static let limit = 8

    public static func json(_ sessions: [Source]) -> String {
        // Terminals have no state to show: only conversations.
        let live = sessions.filter { !$0.info.archived && !$0.info.ended && !$0.info.agent.isShell }
            .sorted { ($0.info.updated ?? $0.info.created) > ($1.info.updated ?? $1.info.created) }
            .prefix(limit)
        let rows: [JSONValue] = live.map { source in
            let info = source.info
            let state = info.pendingApproval != nil ? "waiting" : info.busy ? "working" : info.goal != nil ? "goal" : "idle"
            return .object(["computer": .string(source.computer), "address": .string(source.address), "session": .string(info.id),
                            "title": .string(info.title.isEmpty ? info.agent.title : info.title),
                            "preview": .string(info.preview ?? ""), "state": .string(state),
                            "updated": .number(info.updated ?? info.created)])
        }
        return JSONValue.object(["sessions": .array(rows)]).encoded()
    }

    /// The widget's JSON with what a push says of one session taken in:
    /// its row's state and time changed, or a row made for a session not
    /// shown yet, and the rows put latest first again. Nil when the push
    /// says nothing of a session's state (an older server's, a test's).
    public static func json(_ json: String, applying push: [String: String]) -> String? {
        guard let session = push["session"], !session.isEmpty, let state = push["state"], !state.isEmpty else { return nil }
        let address = push["computer"] ?? ""
        let updated = push["updated"].flatMap(Double.init)
        var rows = parseJSON(json)?["sessions"].array ?? []
        if let index = rows.firstIndex(where: { $0["session"].string == session && $0["address"].string == address }),
           case .object(var row) = rows[index] {
            row["state"] = .string(state)
            if let updated { row["updated"] = .number(updated) }
            if let title = push["title"], !title.isEmpty { row["title"] = .string(title) }
            rows[index] = .object(row)
        } else {
            rows.append(.object(["computer": .string(push["name"] ?? address), "address": .string(address), "session": .string(session),
                                 "title": .string(push["title"] ?? ""), "preview": .string(""), "state": .string(state),
                                 "updated": .number(updated ?? 0)]))
        }
        rows.sort { ($0["updated"].double ?? 0) > ($1["updated"].double ?? 0) }
        return JSONValue.object(["sessions": .array(Array(rows.prefix(limit)))]).encoded()
    }
}
