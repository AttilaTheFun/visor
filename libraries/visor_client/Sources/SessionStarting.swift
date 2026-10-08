/// How a server's new sessions are set up, which the compose sheet follows:
/// a computer's start in one of its folders and are sent their first
/// message once open; a hosted backend's may start from its own named
/// choices, and only with their first message.
public struct SessionStarting: Sendable, Equatable {
    /// A new session starts from one of the server's own named choices (a
    /// hosted backend's templates, `AgentServer.startChoices`) in place of
    /// a folder of the computer.
    public var fromChoices: Bool
    /// A session starts only with its first message (a hosted run needs
    /// its prompt to start): the sheet asks for it, and Start sends it.
    public var withFirstMessage: Bool

    public init(fromChoices: Bool = false, withFirstMessage: Bool = false) {
        self.fromChoices = fromChoices
        self.withFirstMessage = withFirstMessage
    }

    /// A computer's: in a folder, the first message sent once it is open.
    public static let inFolders = SessionStarting()
}
