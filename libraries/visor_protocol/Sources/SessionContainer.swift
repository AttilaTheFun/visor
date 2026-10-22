/// Where a session's agent runs when it is not on the computer itself: a
/// container that an oss server hosts (oss's agent sessions: an Apple
/// container on a Mac, a Podman or Docker one on Linux), which the Visor
/// server drives over oss's API. The agent's folder is the container's
/// (`SessionInfo.cwd`, under `/root/work`).
public struct SessionContainer: Codable, Hashable, Sendable {
    /// The oss server it is on (its API's address).
    public var server: String
    /// oss's own id for the session.
    public var id: String
    /// The GitHub repository cloned into it (owner/name), when one was.
    public var repository: String?
    /// The image it was made from, when not oss's own.
    public var image: String?

    public init(server: String, id: String, repository: String? = nil, image: String? = nil) {
        self.server = server
        self.id = id
        self.repository = repository
        self.image = image
    }
}
