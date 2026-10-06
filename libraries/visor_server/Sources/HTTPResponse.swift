public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: String
    public init(_ status: Int, _ body: String = "") { self.status = status; self.body = body }
    public static func json(_ text: String) -> HTTPResponse { HTTPResponse(200, text) }
}
