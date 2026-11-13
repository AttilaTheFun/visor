// A front's word, for a server whose auth is `none` (docs/server-proxy.md,
// "Auth"): a sign-in of its own in front of the server (MultiPass, or a
// company's reverse proxy) names the person in headers the server is told
// of, and the server takes that word only for a reason it is told: the
// front's token on the request, or nothing but the front being able to
// reach where the server listens. Nothing here names any front.

import Foundation

public struct FrontTrust: Equatable, Sendable {
    /// Why a request may name its person.
    public enum Trust: Equatable, Sendable {
        /// Only the front reaches where the server listens.
        case listener
        /// The request carries the front's token in this header.
        case token(header: String, value: String)
    }

    public var trust: Trust
    /// The header with the person's stable id; none: everyone is `owner`.
    public var userHeader: String?
    /// The header with the name to show; none: the id.
    public var userNameHeader: String?
    /// The header with the device's name, if the front says it.
    public var deviceHeader: String?

    public init(trust: Trust, userHeader: String? = nil, userNameHeader: String? = nil, deviceHeader: String? = nil) {
        self.trust = trust
        self.userHeader = userHeader
        self.userNameHeader = userNameHeader
        self.deviceHeader = deviceHeader
    }

    /// Whether a request with these headers (their names in lower case)
    /// came from the front.
    func admits(_ headers: [String: String]) -> Bool {
        switch trust {
        case .listener:
            return true
        case .token(let header, let value):
            guard let given = headers[header.lowercased()] else { return false }
            return Self.same(Array(given.utf8), Array(value.utf8))
        }
    }

    /// Whether two tokens are the same, every byte looked at whichever
    /// differs first, so how far they agree takes no longer to find.
    static func same(_ given: [UInt8], _ kept: [UInt8]) -> Bool {
        var differs = UInt8(given.count == kept.count ? 0 : 1)
        for index in kept.indices { differs |= kept[index] ^ (index < given.count ? given[index] : 0) }
        return differs == 0 && !kept.isEmpty
    }

    /// The person a front's request names: their id (`owner` without one),
    /// the name to show, and the device.
    func person(_ headers: [String: String]) -> (id: String, name: String, device: String?) {
        let id = userHeader.flatMap { headers[$0.lowercased()] }.flatMap { $0.isEmpty ? nil : $0 } ?? "owner"
        let name = userNameHeader.flatMap { headers[$0.lowercased()] }.flatMap { $0.isEmpty ? nil : $0 } ?? id
        return (id, name, deviceHeader.flatMap { headers[$0.lowercased()] })
    }
}
