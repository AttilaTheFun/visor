// Where a Visor server is reached: a URL, or a bare name. A Mac behind
// Tailscale Serve is reached at its tailnet name, HTTPS on 443 at the
// root, so a bare name means `https://<name>`. Anything else that fronts
// a server — a reverse proxy, a tunnel, a port on a LAN — is written as
// the URL the client should use, scheme and all, with a path where the
// server is mounted below the root (`https://proxy.example/visor`). The
// socket and the one-shot calls are found from it.
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
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            root = String(value)
        } else if lowered.hasPrefix("ws://") || lowered.hasPrefix("wss://") {
            // The socket's form, typed by someone who had it to hand.
            root = (lowered.hasPrefix("wss") ? "https" : "http") + String(value.dropFirst(lowered.hasPrefix("wss") ? 3 : 2))
        } else {
            root = "https://" + String(value)
        }
    }

    /// The live channel: the socket at the root, `ws` for `http`.
    public var socket: String {
        root.lowercased().hasPrefix("https://") ? "wss://" + root.dropFirst(8) + "/" : "ws://" + root.dropFirst(7) + "/"
    }

    /// The one-shot calls, under `/api`.
    public var api: String { root + "/api" }

    /// Whether this is the Tailscale form: a bare name, HTTPS at the root.
    public var isBareName: Bool { root.hasPrefix("https://") && !root.dropFirst(8).contains("/") && !root.dropFirst(8).contains(":") }

    /// What to show for it: the bare name where that is all there is,
    /// else the URL.
    public var display: String { isBareName ? String(root.dropFirst(8)) : root }
}
