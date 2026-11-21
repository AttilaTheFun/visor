// sessions/rootfs.json: the image the Sessions container's root filesystem
// was cloned from. It's kept across starts (what agents installed in it
// stays) while the image is the same; a new image (a release's, or
// Settings') gives it a new clone at its next start, which is only ever
// once it's idle.

import Foundation

struct RootfsRecord: Codable, Equatable, Sendable {
    /// The image's digest (`sha256:…`).
    var image: String
    /// The template it was cloned from.
    var template: String

    static func read(_ url: URL) -> RootfsRecord? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(RootfsRecord.self, from: $0) }
    }

    func write(_ url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
