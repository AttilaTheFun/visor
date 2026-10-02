#if canImport(Foundation)
import Foundation
#endif

/// A streamed assistant message in a snapshot: its id and its words so far.
public struct StreamChunk: Codable, Hashable, Sendable {
    public var id: String
    public var text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}
