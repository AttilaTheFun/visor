#if canImport(Foundation)
import Foundation
#endif

public struct TaskItem: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable { case pending, active, done }
    public var title: String
    public var state: State
    public init(title: String, state: State) { self.title = title; self.state = state }
}
