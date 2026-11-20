// Super Compact's settings (docs/super-compact.md): the model of each tier
// of its cascade — Haiku maps the transcript's chunks, Sonnet merges what
// they found, Opus writes HANDOFF.md (Logan, 20 Nov 2026) — and how large
// a chunk and a merge's group are. Kept in the server's settings
// (`ServerSettings.superCompact`); none there is these defaults.

import Foundation

public struct SuperCompactSettings: Codable, Equatable, Sendable {
    /// The map's model, for each chunk in turn, the ledger carried forward:
    /// what `claude --model` takes (Claude Code's alias for the latest
    /// Haiku, or a model's full id).
    public var mapModel = "haiku"
    /// The merge's: the chunks' ledgers and chapters, in groups, then
    /// groups of groups, into one ledger and timeline.
    public var mergeModel = "sonnet"
    /// The final step's: HANDOFF.md, from the merged ledger and timeline.
    public var finalModel = "opus"
    /// About how many tokens of the filtered transcript each map call
    /// reads (at four characters a token); Haiku's window is 200,000.
    public var chunkTokens = 120_000
    /// How many parts each merge call combines.
    public var mergeGroup = 8

    public init() {}

    /// Characters per token, as the chunks are measured.
    public static let charactersPerToken = 4

    /// A chunk's size in characters: never less than a thousand tokens'.
    public var chunkCharacters: Int { max(chunkTokens, 1_000) * Self.charactersPerToken }

    /// A merge's group: never less than two, so the merge ends.
    public var group: Int { max(mergeGroup, 2) }

    enum CodingKeys: String, CodingKey { case mapModel, mergeModel, finalModel, chunkTokens, mergeGroup }

    // Field by field: one missing (or empty) reads as its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func model(_ key: CodingKeys, _ fallback: String) -> String {
            let given = ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil)?.trimmingCharacters(in: .whitespaces) ?? ""
            return given.isEmpty ? fallback : given
        }
        mapModel = model(.mapModel, "haiku")
        mergeModel = model(.mergeModel, "sonnet")
        finalModel = model(.finalModel, "opus")
        chunkTokens = ((try? c.decodeIfPresent(Int.self, forKey: .chunkTokens)) ?? nil) ?? 120_000
        mergeGroup = ((try? c.decodeIfPresent(Int.self, forKey: .mergeGroup)) ?? nil) ?? 8
    }
}
