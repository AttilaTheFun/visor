import Foundation

public struct GitHubResponse: Sendable {
    public var status: Int
    /// Field names lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
    public var isRedirect: Bool { [301, 302, 303, 307, 308].contains(status) }
    public var location: String? { headers["location"] }
    public var text: String { String(decoding: body, as: UTF8.self) }
}
