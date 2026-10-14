import VisorProtocol

/// A message an agent here sent to a session on another server, as this
/// server's relay outbox keeps it: waiting for a client connected to both
/// to carry it, then what became of it there.
struct RelayRecord: Codable, Equatable {
    enum Status: String, Codable {
        /// In the outbox, for a client to carry.
        case waiting
        /// Taken there: sent to the session at once, queued while it
        /// works, or read.
        case sent, queued, read
        /// Not taken there (no such session).
        case failed
        /// Not carried before it expired.
        case expired
    }

    var message: RelayMessage
    var status: Status
    /// What a read found, or what went wrong.
    var result: String
    /// When the status last changed, in seconds since 1970.
    var updated: Double
}
