// An MCP server this server passes on to its sessions' agents (MCPProxy):
// where it is, the headers each request to it carries, and whether a
// session gets it unless switched off. A header's value may name the
// session (`$SESSION_ID`, `$SESSION_TITLE`); a secret one is kept with the
// server's secrets, never in its settings, a session or a container.

import Foundation

public struct MCPEndpoint: Codable, Equatable, Sendable {
    /// What its tools are listed under (`<name>__<tool>`): letters, digits,
    /// `-` and `_`, without `__`.
    public var name: String
    /// Its Streamable HTTP address (`http://127.0.0.1:7470/mcp`).
    public var url: String
    public var headers: [Header]
    /// Whether a session gets it unless the session switches it off.
    public var onByDefault: Bool

    public init(name: String, url: String, headers: [Header] = [], onByDefault: Bool = true) {
        self.name = name
        self.url = url
        self.headers = headers
        self.onByDefault = onByDefault
    }

    /// A header each request carries.
    public struct Header: Codable, Equatable, Sendable {
        public var name: String
        /// Its value, with `$SESSION_ID` and `$SESSION_TITLE` filled in per
        /// session; empty for a secret one, whose value is kept apart.
        public var value: String
        public var secret: Bool

        public init(name: String, value: String = "", secret: Bool = false) {
            self.name = name
            self.value = value
            self.secret = secret
        }
    }

    /// Why it can't be kept as it is, if it can't.
    public var problem: String? {
        if !Self.validName(name) { return "\"\(name)\" can't name an endpoint: letters, digits, - and _ only, at most 24, without __." }
        guard let parsed = URL(string: url), let scheme = parsed.scheme, ["http", "https"].contains(scheme), parsed.host != nil else {
            return "\(url) is not an http(s) address."
        }
        if let bad = headers.first(where: { $0.name.isEmpty || $0.name.contains(where: { $0 == ":" || $0.isWhitespace }) }) {
            return "\"\(bad.name)\" can't name a header."
        }
        return nil
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 24 && !name.contains("__")
            && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
    }

    /// Where a secret header's value is kept with the server's secrets.
    public static func secretKey(endpoint: String, header: String) -> String { "mcpHeader \(endpoint) \(header.lowercased())" }

    /// The headers a session's requests carry: each value with the session
    /// filled in, a secret one as kept.
    func filledHeaders(session: String, title: String, secrets: any SecretStore) -> [String: String] {
        var filled: [String: String] = [:]
        for header in headers {
            let value = header.secret ? (secrets.get(Self.secretKey(endpoint: name, header: header.name)) ?? "") : header.value
            filled[header.name] = value.replacingOccurrences(of: "$SESSION_ID", with: session)
                .replacingOccurrences(of: "$SESSION_TITLE", with: title)
        }
        return filled
    }
}
