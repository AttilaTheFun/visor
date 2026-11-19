// The two volumes, and what each must be.

/// Which of Visor's two volumes a volume is.
public enum VolumeRole: String, Codable, CaseIterable, Sendable {
    /// The sessions' working folders (`/Volumes/Sessions/<Agent>/<id>`), the
    /// container's harness folder (`/Volumes/Sessions/.claude`) and staged
    /// exports: what must survive. Never erased.
    case sessions
    /// The container's image, root filesystem, caches and logs: what can be
    /// thrown away and made again.
    case containers

    /// The volume's name, and so its mount point's.
    public var volumeName: String {
        switch self {
        case .sessions: "Sessions"
        case .containers: "Containers"
        }
    }

    /// Where it's mounted: `/Volumes/<name>`, the same path the Sessions
    /// container mounts it at.
    public var mountPoint: String { "/Volumes/\(volumeName)" }

    /// The APFS personality it's made with (`diskutil apfs addVolume`'s
    /// <fs>). Both are case-sensitive: Sessions holds folders a Linux
    /// container works in, and Containers' caches and logs are shared into
    /// the same Linux container, where `Foo.h` and `foo.h` are two files.
    /// (The container's own image and root filesystem are ext4 block files,
    /// which don't mind either way.)
    public var personality: String { "Case-sensitive APFS" }

    /// Whether it should be case-sensitive.
    public var wantsCaseSensitive: Bool { true }

    /// Whether Visor Disk Utility may ever erase it: Containers alone.
    public var isErasable: Bool { self == .containers }

    /// What it's for, in a line.
    public var purpose: String {
        switch self {
        case .sessions: "The sessions' working folders, the container's .claude folder and staged exports. Never erased."
        case .containers: "The container's image, root filesystem, caches and logs. Can be erased and made again."
        }
    }

    /// The space set aside for it when it's made, in bytes (a reserve is
    /// space no other volume can take).
    public var defaultReserve: Int64 {
        switch self {
        case .sessions: 20 * ByteSize.gigabyte
        case .containers: 0
        }
    }

    /// The most it may hold when it's made, in bytes (0: no limit but the
    /// disk's).
    public var defaultQuota: Int64 {
        switch self {
        case .sessions: 0
        case .containers: 200 * ByteSize.gigabyte
        }
    }
}
