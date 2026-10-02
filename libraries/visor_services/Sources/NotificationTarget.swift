/// A notification the user opened: which session, on which computer (by
/// the address the client knows it at).
public struct NotificationTarget: Sendable, Equatable {
    public let computer: String
    public let session: String
    public init(computer: String, session: String) {
        self.computer = computer
        self.session = session
    }
}
