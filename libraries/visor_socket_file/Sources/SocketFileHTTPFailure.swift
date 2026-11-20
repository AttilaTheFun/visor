/// A request at a socket file that was not answered with a 2xx: its status
/// (0 when there was no answer at all) and what came with it.
public struct SocketFileHTTPFailure: Error, CustomStringConvertible, Sendable {
    public let status: Int
    public let body: String

    public init(status: Int, body: String) {
        self.status = status
        self.body = body
    }

    public var description: String { "HTTP \(status): \(body.prefix(200))" }
}
