// Where a Visor server is reached: a URL, or a bare name. A name alone
// means HTTPS at the root (`https://<name>`), as a name on a network with
// certificates gives it. Anything else — the server's own port on a LAN
// or a VPN, a reverse proxy, a tunnel — is written as the URL the client
// should use, scheme and all, with a path where the server is mounted
// below the root (`https://proxy.example/visor`). The socket and the
// one-shot calls are found from it.
//
// By hand, without Foundation's URL: the same code runs in the web client.

public struct ServerAddress: Equatable, Hashable, Sendable {
    /// The server's root over HTTP: scheme, host, port and mount path, no
    /// trailing slash (`https://mac.tail.ts.net`, `http://10.0.0.5:7434`,
    /// `https://proxy.example/visor`).
    public let root: String

    /// From what the user typed or a code carried: trimmed, a bare name
    /// made `https://`, a trailing slash dropped. Nil when empty.
    public init?(_ text: String) {
        var value = Substring(text)
        while let first = value.first, first.isWhitespace || first.isNewline { value = value.dropFirst() }
        while let last = value.last, last.isWhitespace || last.isNewline || last == "/" { value = value.dropLast() }
        guard !value.isEmpty else { return nil }
        let lowered = value.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix(SocketFileURL.httpScheme) {
            root = String(value)
        } else if lowered.hasPrefix("ws://") || lowered.hasPrefix("wss://") {
            // The socket's form, typed by someone who had it to hand.
            root = (lowered.hasPrefix("wss") ? "https" : "http") + String(value.dropFirst(lowered.hasPrefix("wss") ? 3 : 2))
        } else {
            root = "https://" + String(value)
        }
    }

    /// The live channel: the socket at the root, `ws` for `http` (and
    /// `ws+unix` for a socket file's, SocketFileURL).
    public var socket: String {
        let lowered = root.lowercased()
        if lowered.hasPrefix(SocketFileURL.httpScheme) { return SocketFileURL.socketScheme + root.dropFirst(SocketFileURL.httpScheme.count) + "/" }
        return lowered.hasPrefix("https://") ? "wss://" + root.dropFirst(8) + "/" : "ws://" + root.dropFirst(7) + "/"
    }

    /// Whether this is a server's socket file on this computer
    /// (SocketFileURL).
    public var isSocketFile: Bool { SocketFileURL.isSocketFile(root) }

    /// The one-shot calls, under `/api`.
    public var api: String { root + "/api" }

    /// Whether this is a bare name: HTTPS at the root, nothing else said.
    public var isBareName: Bool { root.hasPrefix("https://") && !root.dropFirst(8).contains("/") && !root.dropFirst(8).contains(":") }

    /// What to show for it: the bare name where that is all there is, the
    /// socket file's path for one, else the URL.
    public var display: String {
        if let file = SocketFileURL.split(root) { return file.socket }
        return isBareName ? String(root.dropFirst(8)) : root
    }
}
