// The APFS containers `diskutil apfs list -plist` lists.

import Foundation

/// One APFS container and its volumes.
public struct APFSContainer: Codable, Equatable, Sendable {
    /// Its disk, `disk3`: `diskutil apfs addVolume`'s <containerRefDisk>.
    public var reference: String
    public var uuid: String
    /// Its whole size, in bytes.
    public var capacity: Int64
    /// What none of its volumes holds or reserves, in bytes: shared by all.
    public var free: Int64
    public var volumes: [APFSVolume]

    public init(reference: String, uuid: String = "", capacity: Int64 = 0, free: Int64 = 0, volumes: [APFSVolume] = []) {
        self.reference = reference
        self.uuid = uuid
        self.capacity = capacity
        self.free = free
        self.volumes = volumes
    }

    private enum CodingKeys: String, CodingKey {
        case reference = "ContainerReference"
        case uuid = "APFSContainerUUID"
        case capacity = "CapacityCeiling"
        case free = "CapacityFree"
        case volumes = "Volumes"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        reference = try values.decode(String.self, forKey: .reference)
        uuid = try values.decodeIfPresent(String.self, forKey: .uuid) ?? ""
        capacity = try values.decodeIfPresent(Int64.self, forKey: .capacity) ?? 0
        free = try values.decodeIfPresent(Int64.self, forKey: .free) ?? 0
        volumes = try values.decodeIfPresent([APFSVolume].self, forKey: .volumes) ?? []
    }

    /// The containers in `diskutil apfs list -plist`'s output.
    public static func list(fromPlist data: Data) throws -> [APFSContainer] {
        do {
            return try PropertyListDecoder().decode(Listing.self, from: data).containers
        } catch {
            throw DiskVolumesError.unreadable("diskutil apfs list -plist", "\(error)")
        }
    }

    /// The listing's top level.
    private struct Listing: Decodable {
        var containers: [APFSContainer]
        private enum CodingKeys: String, CodingKey { case containers = "Containers" }
    }
}
