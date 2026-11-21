// volumes.json: what Visor Disk Utility leaves for Visor.

import Foundation

/// The volumes as Visor Disk Utility last found them, written to Visor's
/// data folder (VisorFolders.data: `/Volumes/Visor/Data/volumes.json` once
/// the Visor volume is there, else `~/Library/Application
/// Support/Visor/volumes.json`) each time it looks. Visor reads it through DiskVolumes, and checks the mount
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
    /// The APFS volume UUIDs of Visor's own volumes, by role (`sessions`,
    /// `sources`, `visor`): each found named for its role and mounted at its
    /// mount point (VolumeState.inPlaceUUID), as Visor Disk Utility makes
    /// it, and kept across writes until another is found there. Only these,
    /// or the volume mounted at the role's mount point, may ever be deleted
    /// as that role (VolumeGuard, for Uninstall…): a volume someone else
    /// gave the name, mounted elsewhere, never is.
    public var ownVolumes: [String: String]

    public init(version: Int = Self.currentVersion, updated: Date, volumes: [VolumeRecord], ownVolumes: [String: String] = [:]) {
        self.version = version
        self.updated = updated
        self.volumes = volumes
        self.ownVolumes = ownVolumes
    }

    /// The status of the survey's volumes, keeping the UUIDs of Visor's own
    /// that the file before it recorded (`previous`) unless one is now
    /// found in its place.
    public init(survey: DiskSurvey, updated: Date, previous: VolumesStatus? = nil) {
        var own = previous?.ownVolumes ?? [:]
        for role in VolumeRole.allCases {
            if let uuid = survey.state(for: role).inPlaceUUID { own[role.rawValue] = uuid }
        }
        self.init(updated: updated, volumes: VolumeRole.allCases.compactMap { survey.state(for: $0).record }, ownVolumes: own)
    }

    private enum CodingKeys: String, CodingKey {
        case version, updated, volumes, ownVolumes
    }

    /// A file written before ownVolumes was has none: it decodes as empty.
    /// One of 0.64's has the Containers volume as `containers`: its line
    /// and its UUID read as the Visor volume's (VolumeRole.named), as it
    /// replaced Containers; the Visor volume's own, if the file has one,
    /// stands.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        updated = try values.decode(Date.self, forKey: .updated)
        let lines = try values.decode([VolumeRecord].self, forKey: .volumes)
        volumes = lines.enumerated().filter { index, line in
            !lines[..<index].contains { $0.role == line.role }
        }.map(\.element)
        var own = try values.decodeIfPresent([String: String].self, forKey: .ownVolumes) ?? [:]
        if let retired = own.removeValue(forKey: VolumeRole.retiredContainers), own[VolumeRole.visor.rawValue] == nil {
            own[VolumeRole.visor.rawValue] = retired
        }
        ownVolumes = own
    }

    /// The UUID recorded as Visor's own volume of the role, if any.
    public func ownUUID(for role: VolumeRole) -> String? { ownVolumes[role.rawValue] }

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
