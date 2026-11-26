public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: String
    /// Headers beside those every answer carries (`Retry-After`).
    public var headers: [String: String] = [:]
    public init(_ status: Int, _ body: String = "") { self.status = status; self.body = body }
    public static func json(_ text: String) -> HTTPResponse { HTTPResponse(200, text) }
}
