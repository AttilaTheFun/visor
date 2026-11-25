// The three volumes, and what each must be.

/// Which of Visor's three volumes a volume is. Everything Visor keeps on a
/// Mac is on one of them once they're made (docs/containers.md, Visor's
/// volumes), so deleting them in Apple's Disk Utility, with the apps,
/// leaves the Mac as it was.
public enum VolumeRole: String, CaseIterable, Sendable {
    /// The sessions' working folders (`/Volumes/Sessions/<Agent>/<id>`), the
    /// container's harness folder (`/Volumes/Sessions/.claude`) and staged
    /// exports: what must survive. Never erased.
    case sessions
    /// The sessions' checkouts, shared into the container at the same path
    /// (`/Volumes/Sources`): case-sensitive, as a Linux checkout wants.
    case sources
    /// Visor's own: its data folder (`Data/`), its caches, logs and socket,
    /// and the container's image, root filesystem and caches
    /// (`Containers/`). It replaced 0.64's Containers volume.
    case visor

    /// The volume's name, and so its mount point's.
    public var volumeName: String {
        switch self {
        case .sessions: "Sessions"
        case .sources: "Sources"
        case .visor: "Visor"
        }
    }

    /// Where it's mounted: `/Volumes/<name>`, the same path the Sessions
    /// container mounts it at.
    public var mountPoint: String { "/Volumes/\(volumeName)" }

    /// The APFS personality it's made with (`diskutil apfs addVolume`'s
    /// <fs>). All three are case-sensitive: Sessions and Sources hold
    /// folders a Linux container works in, and the container's caches and
    /// logs on Visor are shared into the same Linux container, where `Foo.h`
    /// and `foo.h` are two files. (The container's own image and root
    /// filesystem are ext4 block files, which don't mind either way.)
    public var personality: String { "Case-sensitive APFS" }

    /// Whether it should be case-sensitive.
    public var wantsCaseSensitive: Bool { true }

    /// What it's for, in a line.
    public var purpose: String {
        switch self {
        case .sessions: "The sessions' working folders, the container's .claude folder and staged exports. Never erased."
        case .sources: "The sessions' checkouts, shared into the container at the same path."
        case .visor: "Visor's data, caches, logs and socket, and the container's image, root filesystem and caches."
        }
    }

    /// The space set aside for it when it's made, in bytes (a reserve is
    /// space no other volume can take).
    public var defaultReserve: Int64 {
        switch self {
        case .sessions: 20 * ByteSize.gigabyte
        case .sources, .visor: 0
        }
    }

    /// The most it may hold when it's made, in bytes (0: no limit but the
    /// disk's).
    public var defaultQuota: Int64 {
        switch self {
        case .sessions, .sources: 0
        case .visor: 200 * ByteSize.gigabyte
        }
    }

    /// The Containers volume's role, as a volumes.json of 0.64's names it.
    public static let retiredContainers = "containers"

    /// The role a volumes.json line (or a command line) names: its own, or
    /// `containers`, which the Visor volume replaced, read as `visor`.
    public static func named(_ text: String) -> VolumeRole? {
        text == retiredContainers ? .visor : VolumeRole(rawValue: text)
    }
}

extension VolumeRole: Codable {
    /// `containers` (a volumes.json of 0.64's) reads as `visor`.
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let role = VolumeRole.named(text) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath,
                                                                    debugDescription: "\(text) isn't one of Visor's volumes"))
        }
        self = role
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
