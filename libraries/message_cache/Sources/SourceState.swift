import Synchronization
import VisorProtocol

/// How far a source (an agent's own file) has been read into the cache.
public struct SourceState: Sendable, Equatable {
    public var path: String
    /// What tells the file apart from another at the same path (an inode).
    public var identity: String
    public var bytes: UInt64
    public var nextSeq: Int
    public init(path: String, identity: String, bytes: UInt64, nextSeq: Int) {
        self.path = path; self.identity = identity; self.bytes = bytes; self.nextSeq = nextSeq
    }
}
