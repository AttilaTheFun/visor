import Foundation

/// A request the server sends.
public struct OutgoingRequest: Sendable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: Data
    /// Seconds before it is given up on.
    public var timeout: Double

    public init(url: String, method: String = "GET", headers: [String: String] = [:], body: Data = Data(), timeout: Double = 15) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    /// What came back: its status, its body, and its headers (names in
    /// lowercase).
    public struct Answer: Sendable {
        public var status: Int
        public var body: Data
        public var headers: [String: String]

        public init(status: Int, body: Data, headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }
    }
}
