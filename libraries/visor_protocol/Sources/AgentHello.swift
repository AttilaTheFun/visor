// A wrapped agent's first word when it dials the server (docs/runners.md, "A
// wrapped agent"): the session it is, and where. Who it is was checked by
// MultiPass, which passes it on (X-Visor-Caller); nothing here is a secret.

/// A wrapped agent saying which session it is, on dialing in.
public struct AgentHello: Codable, Hashable, Sendable {
    /// The runner protocol's version this side speaks (docs/runners.md, "The
    /// runner protocol").
    public static let protocolVersion = 2

    public var protocolVersion: Int
    /// The session's id, its creator's: the same through reconnects, moves
    /// and archiving.
    public var session: String
    public var agent: AgentKind
    /// Its working directory where it runs.
    public var cwd: String
    public var title: String
    /// The runner that started it, by id.
    public var runner: String
    /// The issue or pull request it works on, as URLs.
    public var links: [String]
    public var place: AgentPlace

    public init(session: String, agent: AgentKind, cwd: String, title: String, runner: String, links: [String] = [],
                place: AgentPlace, protocolVersion: Int = Self.protocolVersion) {
        self.protocolVersion = protocolVersion
        self.session = session
        self.agent = agent
        self.cwd = cwd
        self.title = title
        self.runner = runner
        self.links = links
        self.place = place
    }
}
