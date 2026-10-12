/// A session as a client reports it to the servers it is connected to: its
/// id (unique on its server), its name, its agent and whether it is working.
public struct DirectorySession: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var agent: String
    public var busy: Bool

    public init(id: String, name: String, agent: String = "", busy: Bool = false) {
        self.id = id
        self.name = name
        self.agent = agent
        self.busy = busy
    }
}
