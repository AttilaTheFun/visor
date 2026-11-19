// volumes.json: what Visor Disk Utility leaves for Visor.

import Foundation

/// The volumes as Visor Disk Utility last found them, written to Visor's
/// data folder (`~/Library/Application Support/Visor/volumes.json`) each
/// time it looks. Visor reads it through DiskVolumes, and checks the mount
/// points itself too: the file says what the volumes are, the mount points
/// whether they're there now.
public struct VolumesStatus: Codable, Equatable, Sendable {
    /// The file's format; a reader skips a file of a later one.
    public static let currentVersion = 1
    public static let fileName = "volumes.json"

    public var version: Int
    /// When it was written.
    public var updated: Date
    /// The volumes found; a role with none has no line.
    public var volumes: [VolumeRecord]

    public init(version: Int = Self.currentVersion, updated: Date, volumes: [VolumeRecord]) {
        self.version = version
        self.updated = updated
        self.volumes = volumes
    }

    /// The status of the survey's volumes.
    public init(survey: DiskSurvey, updated: Date) {
        self.init(updated: updated, volumes: VolumeRole.allCases.compactMap { survey.state(for: $0).record })
    }

    /// volumes.json in Visor's data folder.
    public static func url(inDataDirectory directory: URL) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }

    public func record(for role: VolumeRole) -> VolumeRecord? { volumes.first { $0.role == role } }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> VolumesStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VolumesStatus.self, from: data)
    }

    /// Writes it atomically, making the folder if it isn't there.
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: .atomic)
    }
}
