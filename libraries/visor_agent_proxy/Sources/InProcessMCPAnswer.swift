import Foundation

/// What an in-process MCP server answers a call with (InProcessMCP): its
/// status, its headers (Content-Type among them; the length and the
/// connection's are the pass-through's) and its body.
public struct InProcessMCPAnswer: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// The status line's words for the statuses MCP's answers use.
    static let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                          405: "Method Not Allowed", 500: "Internal Server Error"]

    /// Its bytes on the wire, the connection closed after it.
    var serialized: Data {
        var head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            let lowered = name.lowercased()
            guard lowered != "content-length", lowered != "connection", lowered != "transfer-encoding",
                  !(name + value).contains(where: { $0 == "\r" || $0 == "\n" }) else { continue }
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
