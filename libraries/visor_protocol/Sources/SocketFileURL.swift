// A server reached at its socket file on this computer
// (`~/.visor/server.sock`, its user's alone), written as a URL the client
// treats like any other address: `http+unix://<the path, percent-encoded>`,
// the convention Docker's and Python's clients use. Its live channel is
// `ws+unix://…/` and its calls `http+unix://…/api/…`; the host's services
// that know the scheme (VisorSocketFile) send them over the socket file,
// and every other URL as before. Visor on the Mac reaches its own server
// this way, as an SSH client reaches a server at its socket file: no
// password asked.
//
// By hand, without Foundation's URL: the same code runs in the web client.

public enum SocketFileURL {
    /// The scheme of the calls, and of the live channel.
    public static let httpScheme = "http+unix://"
    public static let socketScheme = "ws+unix://"

    /// The address of the server at the socket file `path`.
    public static func address(socket path: String) -> String { httpScheme + encode(path) }

    /// Whether an address, or a call's or the channel's URL, is one of
    /// these.
    public static func isSocketFile(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.hasPrefix(httpScheme) || lowered.hasPrefix(socketScheme)
    }

    /// The socket file a URL of these names, and the path of the request
    /// on it (`/api/hello`; `/` for the channel). Nil for any other URL.
    public static func split(_ url: String) -> (socket: String, path: String)? {
        let lowered = url.lowercased()
        let scheme = lowered.hasPrefix(httpScheme) ? httpScheme : lowered.hasPrefix(socketScheme) ? socketScheme : nil
        guard let scheme else { return nil }
        let rest = url.dropFirst(scheme.count)
        let host = rest.prefix { $0 != "/" }
        guard let socket = decode(String(host)), !socket.isEmpty else { return nil }
        let path = rest.dropFirst(host.count)
        return (socket, path.isEmpty ? "/" : String(path))
    }

    /// Every byte but the unreserved percent-encoded: a path's slashes too,
    /// so it is one host.
    static func encode(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            if (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 45 || byte == 46
                || byte == 95 || byte == 126 {
                out.append(Character(Unicode.Scalar(byte)))
            } else {
                let hex = Array("0123456789ABCDEF")
                out += "%" + String(hex[Int(byte >> 4)]) + String(hex[Int(byte & 0x0F)])
            }
        }
        return out
    }

    /// Percent-decoded; nil for a broken escape.
    static func decode(_ text: String) -> String? {
        var bytes: [UInt8] = []
        var iterator = Array(text.utf8).makeIterator()
        while let byte = iterator.next() {
            guard byte == 37 else {
                bytes.append(byte)
                continue
            }
            guard let high = iterator.next().flatMap(hexValue), let low = iterator.next().flatMap(hexValue) else { return nil }
            bytes.append(high << 4 | low)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
}
