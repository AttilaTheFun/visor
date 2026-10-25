/// Where a session's agent runs when it is not on the computer itself: a
/// Linux container the Visor server runs on its own computer (Apple's
/// container on a Mac). The session's folder is the computer's, mounted in
/// the container at the same path, so the agent works on the same files
/// and keeps the same log whichever side it runs on.
public struct SessionContainer: Codable, Hashable, Sendable {
    /// The container's name on the computer.
    public var id: String
    /// The image it was made from.
    public var image: String?

    public init(id: String, image: String? = nil) {
        self.id = id
        self.image = image
    }
}
