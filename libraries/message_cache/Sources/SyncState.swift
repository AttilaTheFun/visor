import Synchronization
import VisorProtocol

/// How far a session has been synced from the server: the revision held
/// and the generation of the rows.
public struct SyncState: Sendable, Equatable {
    public var revision: Int
    public var generation: Int
    public init(revision: Int, generation: Int) { self.revision = revision; self.generation = generation }
}
