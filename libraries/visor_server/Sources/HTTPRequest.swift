import Foundation
import Network

public struct HTTPRequest {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: String

    /// The bearer token; "" for a bare `Bearer` (no password).
    public var authorization: String? {
        guard let value = headers["authorization"] else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.first?.lowercased() == "bearer" else { return nil }
        return parts.count == 2 ? String(parts[1]) : ""
    }
}
