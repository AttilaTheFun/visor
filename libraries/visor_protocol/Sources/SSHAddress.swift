// Where a Visor server is reached over SSH: the computer's own `sshd`, as
// `user@host[:port]` or `ssh://user@host[:port]`, through jump hosts if
// need be (`?via=user@jump[:port],user@jump2`, nearest first, as
// OpenSSH's -J lists them). The client opens the connection itself and
// reaches the server on the computer's loopback through it; everything
// above that is the wire protocol as over any address. Where the server's
// socket file is (`?socket=<path, percent-encoded>`, 0.66), when the
// server says: what `nc -U` is run on there (`attachCommand`); without
// it, the places it has been in turn. An address of a client before 0.66
// passes over `socket`, as over any other key it doesn't know.
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
    /// The server's socket file on the computer, as the server gave it;
    /// nil when it gave none.
    public var socket: String?

    public init(target: Hop, via: [Hop] = [], socket: String? = nil) {
        self.target = target
        self.via = via
        self.socket = socket
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
        var socket: String?
        if let question = value.firstIndex(of: "?") {
            let query = value[value.index(after: question)...]
            value = value[..<question]
            for pair in query.split(separator: "&") {
                guard let equals = pair.firstIndex(of: "=") else { return nil }
                let given = pair[pair.index(after: equals)...]
                if pair[..<equals] == "socket" {
                    guard let path = SocketFileURL.decode(String(given)), !path.isEmpty else { return nil }
                    socket = path
                    continue
                }
                guard pair[..<equals] == "via" else { continue }
                for hop in given.split(separator: ",") {
                    guard let parsed = Hop(hop) else { return nil }
                    via.append(parsed)
                }
            }
        }
        guard let target = Hop(value) else { return nil }
        self.init(target: target, via: via, socket: socket)
    }

    /// `socket=<path, percent-encoded>`: the query an address carries the
    /// server's socket file in.
    public static func socketQuery(_ path: String) -> String { "socket=" + SocketFileURL.encode(path) }

    /// What reaches the server's socket file on the computer, run there for
    /// each connection, in `sh` whatever the user's own shell is: `nc -U`
    /// on the path the server gave, else `defaultAttachCommand`. A path
    /// `sh` would read more into than a path (a quote, `$`, `\\`, a
    /// backquote, a line's end) is not run: the default instead.
    public var attachCommand: String {
        guard let socket, !socket.isEmpty, !socket.contains(where: { "'\"$`\\\n\r".contains($0) }) else { return Self.defaultAttachCommand }
        return "sh -c 'exec nc -U \"\(socket)\"'"
    }

    /// The places the socket file has been, in turn, for a server that
    /// gave none: the Visor volume's (0.65; a link to the group's in 0.66),
    /// the app group's container's (0.66, behind a setting; 0.67's), and
    /// `~/.visor`'s (before the volume; a link to the one placed, for a
    /// release).
    public static let defaultAttachCommand = "sh -c 'if [ -S /Volumes/Visor/run/server.sock ]; then exec nc -U /Volumes/Visor/run/server.sock; "
        + "elif [ -S \"$HOME/Library/Group Containers/group.com.LoganShire.Visor/r/server.sock\" ]; then "
        + "exec nc -U \"$HOME/Library/Group Containers/group.com.LoganShire.Visor/r/server.sock\"; "
        + "else exec nc -U \"$HOME/.visor/server.sock\"; fi'"

    /// What to show for it: `user@host`, and the way there when there is one.
    public var display: String { target.text + (via.isEmpty ? "" : " via " + via.map(\.text).joined(separator: ", ")) }

    /// Where the computer's host key is kept, by hop.
    public static func hostKeySetting(_ hop: Hop) -> String { "ssh.hostkey.\(hop.user)@\(hop.host):\(hop.port)" }
}
