// A session's id as one component of a path the server makes, removes or
// reads (its token file's folder, a backup's folder for it, its own
// working folder): ids come from clients (a `start`'s, a fork's, a backup's
// manifest), so one may be `.`, `..`, empty, or hold a `/`. An id of
// letters, digits, `-` and `_` alone (every UUID, so every id the server or
// a client makes) is its own name; any other is `+` and the first 32 hex
// digits of its SHA-256, which can't be `.`, `..` or empty, can't hold a
// separator, and can't be another id's own name (no plain id holds a `+`).

import Crypto
import Foundation

package enum SessionPathName {
    /// The longest id that is its own name.
    static let longestPlain = 64

    /// `id` as one path component: never `.`, `..` or empty, never with a
    /// separator, and different for different ids.
    package static func of(_ id: String) -> String {
        if isPlain(id) { return id }
        let digest = SHA256.hash(data: Data(id.utf8))
        return "+" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `id` is its own name: 1 to `longestPlain` ASCII letters,
    /// digits, `-` and `_`.
    static func isPlain(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= longestPlain
            && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5a).contains($0) || (0x61...0x7a).contains($0) || $0 == 0x2d || $0 == 0x5f }
    }

    /// Whether `url` is strictly inside `folder`, `.` and `..` resolved:
    /// `folder` itself, or anywhere outside it, is not.
    package static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let inner = url.standardizedFileURL.pathComponents
        let outer = folder.standardizedFileURL.pathComponents
        return inner.count > outer.count && Array(inner.prefix(outer.count)) == outer
    }
}
