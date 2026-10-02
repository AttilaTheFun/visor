#if canImport(Darwin)
import Foundation
import Security

public struct VisorHTTPFailure: Error, CustomStringConvertible {
    public let status: Int
    public let body: String
    public var description: String { "HTTP \(status): \(body.prefix(200))" }
}
#endif
