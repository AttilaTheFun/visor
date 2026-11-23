// The proof a copy was made and checked: written by copy-staged at the
// staged volume's root once both sides' manifests are identical, read by
// Swap In, which refuses without it.

import Foundation

/// `.visor-conversion-verified` (JSON) at the root of `<Name>-new`.
public struct ConversionMarker: Codable, Equatable, Sendable {
    public static let fileName = ".visor-conversion-verified"
    public static let currentVersion = 1
    /// The longest a verification stands: after two hours, copy again.
    public static let maxAge: TimeInterval = 2 * 60 * 60
    /// How far ahead of now a marker's time may be (two Macs' clocks, or a
    /// clock set back) before it's taken as wrong.
    public static let clockSlack: TimeInterval = 5 * 60

    public var version: Int
    public var role: VolumeRole
    /// The APFS volume UUIDs of the volume copied from and the one copied to.
    public var sourceUUID: String
    public var newUUID: String
    /// What the manifest holds: regular files, symbolic links, folders.
    public var files: Int
    public var links: Int
    public var directories: Int
    /// The sha256 of the manifest (VolumeManifest, `.content`), the same
    /// on both sides.
    public var manifestSHA256: String
    /// The sha256 of the source's listing (VolumeManifest, `.listing`:
    /// every path's size and modification time): Swap In takes it again,
    /// and refuses if anything changed since the copy.
    public var sourceListingSHA256: String
    /// When the check passed.
    public var verified: Date

    public init(version: Int = Self.currentVersion, role: VolumeRole, sourceUUID: String, newUUID: String, files: Int, links: Int,
                directories: Int, manifestSHA256: String, sourceListingSHA256: String, verified: Date) {
        self.version = version
        self.role = role
        self.sourceUUID = sourceUUID
        self.newUUID = newUUID
        self.files = files
        self.links = links
        self.directories = directories
        self.manifestSHA256 = manifestSHA256
        self.sourceListingSHA256 = sourceListingSHA256
        self.verified = verified
    }

    /// Throws unless it's the marker of this role's copy from `sourceUUID`
    /// to `newUUID`, of a format this reads, and at most two hours old.
    public func check(role: VolumeRole, sourceUUID: String, newUUID: String, now: Date) throws {
        let name = role.stagedName
        guard version <= Self.currentVersion else {
            throw DiskVolumesError.blocked("\(name)'s marker is of a later format (\(version)): use a newer Visor Disk Utility.")
        }
        guard self.role == role else {
            throw DiskVolumesError.blocked("\(name)'s marker is \(self.role.volumeName)'s, not \(role.volumeName)'s: run copy-staged \(role.rawValue) again.")
        }
        guard self.sourceUUID.caseInsensitiveCompare(sourceUUID) == .orderedSame else {
            throw DiskVolumesError.blocked("\(name)'s marker names the source \(self.sourceUUID), but \(role.mountPoint) is \(sourceUUID) now: "
                + "run copy-staged \(role.rawValue) again.")
        }
        guard self.newUUID.caseInsensitiveCompare(newUUID) == .orderedSame else {
            throw DiskVolumesError.blocked("\(name)'s marker names the copy \(self.newUUID), but \(name) is \(newUUID): "
                + "run copy-staged \(role.rawValue) again.")
        }
        let age = now.timeIntervalSince(verified)
        guard age >= -Self.clockSlack else {
            throw DiskVolumesError.blocked("\(name)'s marker is dated \(Self.describe(verified)), ahead of this Mac's clock: "
                + "run copy-staged \(role.rawValue) again.")
        }
        guard age <= Self.maxAge else {
            throw DiskVolumesError.blocked("\(name) was verified \(Int(age / 60)) minutes ago, more than \(Int(Self.maxAge / 60)): "
                + "run copy-staged \(role.rawValue) again, then Swap In.")
        }
    }

    /// The marker's path at a volume's root.
    public static func path(atRoot root: String) -> String { (root as NSString).appendingPathComponent(fileName) }

    /// The marker at a volume's root; nil when there's none. Throws when
    /// there's one that can't be read.
    public static func read(atRoot root: String) throws -> ConversionMarker? {
        let path = path(atRoot: root)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            return try decoded(from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            throw DiskVolumesError.unreadable(path, "\(error)")
        }
    }

    /// Written at a volume's root, atomically.
    public func write(atRoot root: String) throws {
        try encoded().write(to: URL(fileURLWithPath: Self.path(atRoot: root)), options: .atomic)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> ConversionMarker {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ConversionMarker.self, from: data)
    }

    /// A time as the marker writes it.
    static func describe(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// What it says, in a line: "verified 2026-11-23T03:10:00Z: 1204 files, 31 links".
    public var summary: String {
        "verified \(Self.describe(verified)): \(files) files, \(links) links, \(directories) folders, manifest \(manifestSHA256.prefix(12))…"
    }
}
