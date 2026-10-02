#if canImport(Foundation)
import Foundation
#endif

/// A session in an agent's own store on the host, resumable here.
public struct ResumableSession: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var agent: AgentKind
    public var cwd: String
    /// The first prompt, shortened.
    public var title: String
    /// Seconds since 1970 (the file's last change).
    public var timestamp: Double

    public init(id: String, agent: AgentKind, cwd: String, title: String, timestamp: Double) {
        self.id = id
        self.agent = agent
        self.cwd = cwd
        self.title = title
        self.timestamp = timestamp
    }
}
