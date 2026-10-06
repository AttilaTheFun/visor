// Where a Visor server is reached over SSH: the computer's own `sshd`, as
// `user@host[:port]` or `ssh://user@host[:port]`, through jump hosts if
// need be (`?via=user@jump[:port],user@jump2`, nearest first, as
// OpenSSH's -J lists them). The client opens the connection itself and
// reaches the server on the computer's loopback through it; everything
// above that is the wire protocol as over any address.
//
// By hand, without Foundation's URL: the same code runs in the web client.

public struct SSHAddress: Equatable, Hashable, Sendable {
    /// One SSH server on the way: a user, a host, a port (22 unless said).
    public struct Hop: Equatable, Hashable, Sendable {
        public var user: String
        public var host: String
        public var port: Int

        public init(user: String, host: String, port: Int = 22) {
            self.user = user
            self.host = host
            self.port = port
        }

        /// `user@host[:port]`; nil unless it is one.
        public init?(_ text: Substring) {
            guard let at = text.firstIndex(of: "@") else { return nil }
            let user = String(text[..<at])
            var rest = text[text.index(after: at)...]
            var port = 22
            if let colon = rest.lastIndex(of: ":") {
                guard let number = Int(rest[rest.index(after: colon)...]), number > 0, number < 65536 else { return nil }
                port = number
                rest = rest[..<colon]
            }
            guard !user.isEmpty, !rest.isEmpty, !rest.contains("/"), !rest.contains("@") else { return nil }
            self.init(user: user, host: String(rest), port: port)
        }

        /// As written, the port only when it is not 22.
        public var text: String { user + "@" + host + (port == 22 ? "" : ":\(port)") }
    }

    /// The computer the server runs on.
    public var target: Hop
    /// The jump hosts on the way, nearest first.
    public var via: [Hop]

    public init(target: Hop, via: [Hop] = []) {
        self.target = target
        self.via = via
    }

    /// Every connection to make, in order: the jump hosts, then the target.
    public var route: [Hop] { via + [target] }

    /// From what the user typed: trimmed; `ssh://` or nothing before the
    /// user; `?via=` after. Nil when it is not an SSH address (no user, or
    /// another scheme).
    public init?(_ text: String) {
        var value = Substring(text)
        while let first = value.first, first.isWhitespace || first.isNewline { value = value.dropFirst() }
        while let last = value.last, last.isWhitespace || last.isNewline || last == "/" { value = value.dropLast() }
        if value.lowercased().hasPrefix("ssh://") { value = value.dropFirst(6) }
        guard !value.contains("://") else { return nil }
        var via: [Hop] = []
        if let question = value.firstIndex(of: "?") {
            let query = value[value.index(after: question)...]
            value = value[..<question]
            for pair in query.split(separator: "&") {
                guard let equals = pair.firstIndex(of: "=") else { return nil }
                guard pair[..<equals] == "via" else { continue }
                for hop in pair[pair.index(after: equals)...].split(separator: ",") {
                    guard let parsed = Hop(hop) else { return nil }
                    via.append(parsed)
                }
            }
        }
        guard let target = Hop(value) else { return nil }
        self.init(target: target, via: via)
    }

    /// What to show for it: `user@host`, and the way there when there is one.
    public var display: String { target.text + (via.isEmpty ? "" : " via " + via.map(\.text).joined(separator: ", ")) }

    /// Where the computer's host key is kept, by hop.
    public static func hostKeySetting(_ hop: Hop) -> String { "ssh.hostkey.\(hop.user)@\(hop.host):\(hop.port)" }
}
