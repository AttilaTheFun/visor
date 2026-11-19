// One volume's line in volumes.json.

/// A volume as Visor Disk Utility last found it, for Visor to read.
public struct VolumeRecord: Codable, Equatable, Sendable {
    public var role: VolumeRole
    public var name: String
    /// Where it's mounted; nil when it isn't.
    public var path: String?
    /// Its disk, `disk3s7`.
    public var device: String
    /// Its personality, `Case-sensitive APFS`.
    public var format: String
    /// Whether it tells `Foo` from `foo`; nil if unknown.
    public var caseSensitive: Bool?
    /// Bytes it holds as APFS lists them (at least its reserve), its quota
    /// (0: none) and its reserve (0: none).
    public var used: Int64
    public var quota: Int64
    public var reserve: Int64
    /// Bytes it could still take when this was written; nil if unknown.
    public var available: Int64?

    public init(role: VolumeRole, name: String, path: String?, device: String, format: String, caseSensitive: Bool?,
                used: Int64, quota: Int64, reserve: Int64, available: Int64? = nil) {
        self.role = role
        self.name = name
        self.path = path
        self.device = device
        self.format = format
        self.caseSensitive = caseSensitive
        self.used = used
        self.quota = quota
        self.reserve = reserve
        self.available = available
    }
}
