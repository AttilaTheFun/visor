/// Where a session's agent ran when it was not on the computer itself: a
/// Linux container on the Visor server's own computer, the session's folder
/// mounted in it at the same path. Gone in 0.50: still read, from a server
/// or a file of 0.49 or before, so they decode; a server of 0.50 or later
/// runs such a session on the computer, and sets it on none.
public struct SessionContainer: Codable, Hashable, Sendable {
    /// The container's lease from Shireworks.
    public var id: String
    /// The image it was made from.
    public var image: String?
    /// What it was given of the computer; nil for one made before sizes.
    public var size: ContainerSize?
    /// Where commands are run in it on the server's computer (the lease's
    /// socket): kept by the server, never sent to a client. Nil for a
    /// container from before Shireworks ran them (Apple's container).
    public var socket: String?
    /// Where Visor's own Linux programs are in it (`/opt/visor/bin`), when
    /// it was made with them mounted: kept by the server, never sent to a
    /// client. Nil for one made without them, whose agents' MCP server is
    /// the image's Node and the script.
    public var programs: String?

    public init(id: String, image: String? = nil, size: ContainerSize? = nil, socket: String? = nil, programs: String? = nil) {
        self.id = id
        self.image = image
        self.size = size
        self.socket = socket
        self.programs = programs
    }
}
