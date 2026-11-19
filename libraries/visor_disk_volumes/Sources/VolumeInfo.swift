// A volume as `diskutil info -plist <disk or path>` describes it.

import Foundation

/// What `diskutil info -plist` says of a volume.
public struct VolumeInfo: Codable, Equatable, Sendable {
    /// Its disk, `disk3s7`.
    public var device: String
    public var volumeName: String
    /// Where it's mounted; nil when it isn't.
    public var mountPoint: String?
    /// `apfs`, `hfs`…
    public var filesystemType: String
    /// Its personality: `APFS`, `Case-sensitive APFS`…
    public var filesystemName: String
    /// Its APFS container's disk, `disk3`; nil for no APFS volume.
    public var containerReference: String?
    /// Its container's free space, in bytes.
    public var containerFree: Int64?
    public var writable: Bool

    public init(device: String, volumeName: String, mountPoint: String?, filesystemType: String = "apfs",
                filesystemName: String, containerReference: String?, containerFree: Int64? = nil, writable: Bool = true) {
        self.device = device
        self.volumeName = volumeName
        self.mountPoint = mountPoint
        self.filesystemType = filesystemType
        self.filesystemName = filesystemName
        self.containerReference = containerReference
        self.containerFree = containerFree
        self.writable = writable
    }

    /// Whether it tells `Foo` from `foo`: its personality says so
    /// (`Case-sensitive APFS`, `Case-sensitive Journaled HFS+`).
    public var isCaseSensitive: Bool { filesystemName.localizedCaseInsensitiveContains("case-sensitive") }

    /// Whether it's APFS, of either case.
    public var isAPFS: Bool { filesystemType == "apfs" }

    private enum CodingKeys: String, CodingKey {
        case device = "DeviceIdentifier"
        case volumeName = "VolumeName"
        case mountPoint = "MountPoint"
        case filesystemType = "FilesystemType"
        case filesystemName = "FilesystemName"
        case containerReference = "APFSContainerReference"
        case containerFree = "APFSContainerFree"
        case writable = "WritableVolume"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        device = try values.decode(String.self, forKey: .device)
        volumeName = try values.decodeIfPresent(String.self, forKey: .volumeName) ?? ""
        let mounted = try values.decodeIfPresent(String.self, forKey: .mountPoint) ?? ""
        mountPoint = mounted.isEmpty ? nil : mounted
        filesystemType = try values.decodeIfPresent(String.self, forKey: .filesystemType) ?? ""
        filesystemName = try values.decodeIfPresent(String.self, forKey: .filesystemName) ?? ""
        containerReference = try values.decodeIfPresent(String.self, forKey: .containerReference)
        containerFree = try values.decodeIfPresent(Int64.self, forKey: .containerFree)
        writable = try values.decodeIfPresent(Bool.self, forKey: .writable) ?? false
    }

    /// The volume in `diskutil info -plist`'s output.
    public static func from(plist data: Data) throws -> VolumeInfo {
        do {
            return try PropertyListDecoder().decode(VolumeInfo.self, from: data)
        } catch {
            throw DiskVolumesError.unreadable("diskutil info -plist", "\(error)")
        }
    }
}
