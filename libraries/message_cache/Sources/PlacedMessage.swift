import Synchronization
import VisorProtocol

/// A row with its place, and the source line that produced it.
public struct PlacedMessage: Sendable, Equatable {
    public let message: TranscriptEntry
    public let seq: Int
    public let sourceKey: String?
    public init(message: TranscriptEntry, seq: Int, sourceKey: String? = nil) {
        self.message = message; self.seq = seq; self.sourceKey = sourceKey
    }
}
