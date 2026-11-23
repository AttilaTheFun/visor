// What Swap In leaves in Visor's data folder of each swap
// (`volume-conversions.json`), so unswap can tell whether the converted
// volume has changed since: if it has, unswap wants --force.

import Foundation

public struct ConversionNote: Codable, Equatable, Sendable {
    public static let fileName = "volume-conversions.json"

    public var role: VolumeRole
    /// When the swap was done.
    public var swapped: Date
    /// The converted volume's UUID, and the old one's (kept for rollback).
    public var newUUID: String
    public var oldUUID: String
    /// The sha256 of the converted volume's listing just after the swap.
    public var listingSHA256: String

    public init(role: VolumeRole, swapped: Date, newUUID: String, oldUUID: String, listingSHA256: String) {
        self.role = role
        self.swapped = swapped
        self.newUUID = newUUID
        self.oldUUID = oldUUID
        self.listingSHA256 = listingSHA256
    }

    /// The file in Visor's data folder.
    public static func url(inDataDirectory directory: URL) -> URL { directory.appendingPathComponent(fileName, isDirectory: false) }

    /// The notes, by role (`sessions`, `sources`); none when there's no
    /// file, or it can't be read.
    public static func read(at url: URL) -> [String: ConversionNote] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: ConversionNote].self, from: data)) ?? [:]
    }

    /// This note written in, beside the others.
    public func save(at url: URL) throws {
        var notes = Self.read(at: url)
        notes[role.rawValue] = self
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(notes).write(to: url, options: .atomic)
    }
}
