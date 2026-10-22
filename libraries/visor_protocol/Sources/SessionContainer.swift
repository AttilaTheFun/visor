/// Where a session's agent runs when it is not on the computer itself: a
/// container that an oss server hosts (an Apple container on a Mac, a
/// Podman or Docker one on Linux), which the Visor
/// server drives over oss's API. The agent's folder is the container's
/// (`SessionInfo.cwd`, under `/root/work`).
public struct SessionContainer: Codable, Hashable, Sendable {
    /// The oss server it is on (its API's address).
    public var server: String
    /// oss's own id for the container.
    public var id: String
    /// The repository cloned into it (GitHub's owner/name, or a git URL),
    /// when one was.
    public var repository: String?
    /// The image it was made from.
    public var image: String?

    public init(server: String, id: String, repository: String? = nil, image: String? = nil) {
        self.server = server
        self.id = id
        self.repository = repository
        self.image = image
    }
}
