// One volume as Visor finds it.

/// Where a role's volume is, whether it's mounted there, and what
/// volumes.json said of it.
public struct LocatedVolume: Equatable, Sendable {
    public var role: VolumeRole
    /// Where it's mounted (volumes.json's path when it has one), else where
    /// it should be.
    public var path: String
    /// Whether a volume is mounted at `path` now.
    public var isMounted: Bool
    /// volumes.json's line for it, if Visor Disk Utility has written one.
    public var record: VolumeRecord?

    public init(role: VolumeRole, path: String, isMounted: Bool, record: VolumeRecord?) {
        self.role = role
        self.path = path
        self.isMounted = isMounted
        self.record = record
    }

    /// Whether it tells `Foo` from `foo`, as volumes.json says; nil if
    /// unknown.
    public var isCaseSensitive: Bool? { record?.caseSensitive }

    /// Whether Visor can use it: mounted.
    public var isReady: Bool { isMounted }

    /// Its path when Visor can use it; nil when it isn't mounted.
    public var readyPath: String? { isReady ? path : nil }
}
