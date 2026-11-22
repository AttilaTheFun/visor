import Foundation

/// Who is calling: the application its key names, the agent that key acts
/// as, and the CLIENT_ID it sent (a Visor session's id), if any.
public struct Caller: Sendable, Equatable {
    public let application: String
    public let agent: String
    public let client: String?

    public init(application: String, agent: String, client: String?) {
        self.application = application
        self.agent = agent
        self.client = client
    }

    /// `<client id>@<application>`, `-` for no client id.
    public var label: String { "\(client ?? "-")@\(application)" }
}
