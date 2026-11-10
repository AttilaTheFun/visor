/// Where a session's agent runs when it is not on the computer itself: a
/// Linux container leased from the oss server (Shireworks) on the Visor
/// server's own computer. The session's folder is the computer's, mounted
/// in the container at the same path, so the agent works on the same files
/// and keeps the same log whichever side it runs on.
public struct SessionContainer: Codable, Hashable, Sendable {
    /// The container's lease from oss.
    public var id: String
    /// The image it was made from.
    public var image: String?
    /// What it was given of the computer; nil for one made before sizes.
    public var size: ContainerSize?
    /// Where commands are run in it on the server's computer (the lease's
    /// socket): kept by the server, never sent to a client. Nil for a
    /// container from before oss ran them (Apple's container).
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
