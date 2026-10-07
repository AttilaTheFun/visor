#if canImport(Foundation)
import Foundation
#endif

/// One thing a turn is doing or has done, as streamed — the model
/// thinking, a shell running, a monitor watching, a subagent working, a
/// tool called, the task list as it stands. Ephemeral: never the record.
public struct StatusItem: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case thinking, shell, monitor, subagent, tool, tasks }
    public var id: String
    public var kind: Kind
    public var label: String
    public var running: Bool
    /// For `.tasks`: the list as last written.
    public var tasks: [TaskItem]
    public init(id: String, kind: Kind, label: String, running: Bool, tasks: [TaskItem] = []) {
        self.id = id; self.kind = kind; self.label = label; self.running = running; self.tasks = tasks
    }
}
