/// What became of a relayed message where it went, carried back to the
/// server it came from: taken (and sent at once, or queued while the agent
/// works), or failed (no such session), with what a read found.
public struct RelayReceipt: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case sent, queued, read, failed
    }

    public var message: String
    public var outcome: Outcome
    /// What a read found, or what went wrong.
    public var text: String

    public init(message: String, outcome: Outcome, text: String = "") {
        self.message = message
        self.outcome = outcome
        self.text = text
    }
}
