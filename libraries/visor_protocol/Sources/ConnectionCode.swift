// A computer's connection code: what the menu bar app shows (as a string
// to copy and a QR code to scan) and what a client takes to add the
// computer in one step — its name, its address on the network, and its
// password. URL-safe base64 of a small JSON object, so it survives being
// pasted anywhere and put in a link (`visor://connect?code=…`).
//
// By hand, without Foundation: the same code runs in the web client.

public struct ConnectionCode: Equatable, Sendable {
    public var name: String
    /// Where clients reach it: a URL, or a bare name (HTTPS at the root)
    /// (`ServerAddress`).
    public var host: String
    public var password: String
    /// The server's id, when the code is from a server that has one.
    public var id: String
    /// The server's other network paths, as clients read them (`ssh://`
    /// ones among them), after `host`, the one to try first.
    public var paths: [String]

    public init(name: String, host: String, password: String, id: String = "", paths: [String] = []) {
        self.name = name
        self.host = host
        self.password = password
        self.id = id
        self.paths = paths.filter { $0 != host }
    }

    /// The computer as a peer: every address the code carries.
    public var peer: Peer { Peer(id: id, name: name, addresses: [host] + paths, password: password) }

    /// The same code with an SSH path first: for a device that should
    /// come in over SSH, bootstrapping over another path if it must. Nil
    /// when the code carries no SSH path.
    public var preferringSSH: ConnectionCode? {
        guard let ssh = ([host] + paths).first(where: { $0.hasPrefix("ssh://") }) else { return nil }
        return ConnectionCode(name: name, host: ssh, password: password, id: id, paths: ([host] + paths).filter { $0 != ssh })
    }

    public static let scheme = "visor"

    /// The code itself: base64url, no padding.
    public var encoded: String {
        var fields: [String: JSONValue] = ["v": .number(1), "name": .string(name), "host": .string(host), "password": .string(password)]
        if !id.isEmpty { fields["id"] = .string(id) }
        if !paths.isEmpty { fields["paths"] = .array(paths.map(JSONValue.string)) }
        return Base64URL.encode(Array(JSONValue.object(fields).encoded().utf8))
    }

    /// The link a QR code carries; opening it opens Visor with the code.
    public var link: String { "\(Self.scheme)://connect?code=\(encoded)" }

    /// A code, a `visor://connect?code=` link, or either with whitespace
    /// around it; nil for anything else.
    public init?(parsing text: String) {
        var value = Substring(text)
        while let first = value.first, first.isWhitespace || first.isNewline { value = value.dropFirst() }
        while let last = value.last, last.isWhitespace || last.isNewline { value = value.dropLast() }
        if let range = value.range(of: "code=") {
            value = value[range.upperBound...]
            if let end = value.firstIndex(of: "&") { value = value[..<end] }
        }
        guard !value.isEmpty, let bytes = Base64URL.decode(String(value)),
              let json = parseJSON(String(decoding: bytes, as: UTF8.self)),
              let host = json["host"].string, !host.isEmpty else { return nil }
        self.init(name: json["name"].string ?? host, host: host, password: json["password"].string ?? "", id: json["id"].string ?? "",
                  paths: json["paths"].array?.compactMap(\.string) ?? [])
    }
}
