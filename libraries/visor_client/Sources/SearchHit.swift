/// A message that matched a search: where it is and a snippet of it.
public struct SearchHit: Identifiable, Hashable, Sendable {
    public var id: String { session + "/" + message }
    public let session: String
    public let message: String
    public let role: String
    public let snippet: String
    public let title: String
    public let cwd: String
    public init(session: String, message: String, role: String, snippet: String, title: String, cwd: String) {
        self.session = session
        self.message = message
        self.role = role
        self.snippet = snippet
        self.title = title
        self.cwd = cwd
    }
}
