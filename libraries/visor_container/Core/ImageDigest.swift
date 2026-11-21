// An image's digest, as Visor pins one: `sha256:` and 64 lowercase hex
// digits, nothing else (a tag can move; a digest can't).

import Foundation

public struct ImageDigest: Codable, Hashable, Sendable, CustomStringConvertible {
    /// `sha256:<64 hex>`.
    public let value: String

    /// The digest of `text`: a bare digest (`sha256:…`), or a reference by
    /// digest to `repository` (`ghcr.io/attilathefun/visor-agent@sha256:…`).
    /// Nil for anything else: a tag, another repository, another algorithm,
    /// a short or uppercase digest.
    public init?(_ text: String, repository: String = ContainerPins.imageRepository) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var digest = Substring(trimmed)
        if let at = trimmed.firstIndex(of: "@") {
            guard trimmed[..<at] == repository else { return nil }
            digest = trimmed[trimmed.index(after: at)...]
        }
        guard digest.hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count)
        guard hex.count == 64, hex.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        value = String(digest)
    }

    /// The 64 hex digits.
    public var hex: String { String(value.dropFirst("sha256:".count)) }

    /// The first 12, for a person.
    public var short: String { String(hex.prefix(12)) }

    /// The reference pulled: `<repository>@sha256:…`.
    public func reference(in repository: String = ContainerPins.imageRepository) -> String { "\(repository)@\(value)" }

    public var description: String { value }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let digest = ImageDigest(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a sha256 digest: \(text)"))
        }
        self = digest
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
