/// A local notification's id: the computer's address, the session and what
/// it says (a turn finished, an approval, a goal). A newer one with the
/// same id replaces the older, and opening it goes to the session. The
/// parts are apart by U+001E (record separator), since an address may
/// hold "/" (a URL's path).
public struct VisorNotificationID: Sendable, Equatable {
    public static let separator = "\u{1E}"

    public let computer: String
    public let session: String
    public let kind: String

    public init(computer: String, session: String, kind: String) {
        self.computer = computer
        self.session = session
        self.kind = kind
    }

    public var rawValue: String { [computer, session, kind].joined(separator: Self.separator) }

    /// What a session's notifications are grouped under.
    public var thread: String { computer + Self.separator + session }

    /// The computer and session an id names. An id made before the
    /// separator, "<address>/<session>/<kind>", is read from its end: the
    /// kind, the session, and the address before them.
    public static func target(of id: String) -> (computer: String, session: String)? {
        if id.contains(separator) {
            let parts = id.components(separatedBy: separator)
            guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return (parts[0], parts[1])
        }
        let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return nil }
        let computer = parts.dropLast(2).joined(separator: "/")
        let session = parts[parts.count - 2]
        guard !computer.isEmpty, !session.isEmpty else { return nil }
        return (computer, session)
    }
}
