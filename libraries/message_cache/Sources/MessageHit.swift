import Synchronization
import VisorProtocol

/// A row found by its words.
public struct MessageHit: Sendable, Equatable {
    public let session: String
    public let messageID: String
    public let role: TranscriptEntry.Role
    public let snippet: String
    public init(session: String, messageID: String, role: TranscriptEntry.Role, snippet: String) {
        self.session = session; self.messageID = messageID; self.role = role; self.snippet = snippet
    }
}
