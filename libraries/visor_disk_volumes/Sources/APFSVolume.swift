// A volume as `diskutil apfs list -plist` lists it.

/// One APFS volume in a container.
public struct APFSVolume: Codable, Equatable, Sendable {
    /// Its disk, `disk3s7`.
    public var device: String
    public var name: String
    public var uuid: String
    /// Bytes it holds now, as APFS counts them: at least its reserve.
    public var used: Int64
    /// The most it may hold, in bytes; 0 for no quota.
    public var quota: Int64
    /// Bytes set aside for it alone; 0 for none.
    public var reserve: Int64
    /// Its roles (`System`, `Data`, `Preboot`…); none for a volume of ours.
    public var roles: [String]

    public init(device: String, name: String, uuid: String = "", used: Int64 = 0, quota: Int64 = 0,
                reserve: Int64 = 0, roles: [String] = []) {
        self.device = device
        self.name = name
        self.uuid = uuid
        self.used = used
        self.quota = quota
        self.reserve = reserve
        self.roles = roles
    }

    private enum CodingKeys: String, CodingKey {
        case device = "DeviceIdentifier"
        case name = "Name"
        case uuid = "APFSVolumeUUID"
        case used = "CapacityInUse"
        case quota = "CapacityQuota"
        case reserve = "CapacityReserve"
        case roles = "Roles"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        device = try values.decode(String.self, forKey: .device)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        uuid = try values.decodeIfPresent(String.self, forKey: .uuid) ?? ""
        used = try values.decodeIfPresent(Int64.self, forKey: .used) ?? 0
        quota = try values.decodeIfPresent(Int64.self, forKey: .quota) ?? 0
        reserve = try values.decodeIfPresent(Int64.self, forKey: .reserve) ?? 0
        roles = try values.decodeIfPresent([String].self, forKey: .roles) ?? []
    }
}
