// What diskutil says of this Mac's disks, gathered once.

/// The boot disk's APFS container, every APFS container and volume, and
/// `diskutil info` of the volumes that matter (those named Sessions or
/// Containers, and whatever is mounted at their mount points).
public struct DiskSurvey: Equatable, Sendable {
    /// The APFS container the system boots from (`diskutil info -plist /`'s
    /// APFSContainerReference), where new volumes are made.
    public var bootContainer: String
    public var containers: [APFSContainer]
    public var infos: [VolumeInfo]
    /// Mount points with a plain folder at them, not a volume: a new volume
    /// would be mounted beside it (`/Volumes/Sessions 1`).
    public var foldersInTheWay: Set<String>
    /// What the filesystem says each mounted volume can still take, by
    /// mount point (statfs's available bytes): exact, where the APFS
    /// listing counts an unused reserve as used.
    public var freeSpace: [String: Int64]

    public init(bootContainer: String, containers: [APFSContainer], infos: [VolumeInfo] = [], foldersInTheWay: Set<String> = [],
                freeSpace: [String: Int64] = [:]) {
        self.bootContainer = bootContainer
        self.containers = containers
        self.infos = infos
        self.foldersInTheWay = foldersInTheWay
        self.freeSpace = freeSpace
    }

    /// The volumes to ask `diskutil info -plist` about: those named for a
    /// role, by disk.
    public static func devicesToDescribe(in containers: [APFSContainer]) -> [String] {
        let names = Set(VolumeRole.allCases.map(\.volumeName))
        return containers.flatMap(\.volumes).filter { names.contains($0.name) }.map(\.device)
    }

    /// A volume by its disk, and the container it's in.
    public func volume(device: String) -> (volume: APFSVolume, container: APFSContainer)? {
        for container in containers {
            if let volume = container.volumes.first(where: { $0.device == device }) { return (volume, container) }
        }
        return nil
    }

    /// A volume by its APFS volume UUID (of either case), and the container
    /// it's in.
    public func volume(uuid: String) -> (volume: APFSVolume, container: APFSContainer)? {
        for container in containers {
            if let volume = container.volumes.first(where: { !$0.uuid.isEmpty && $0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }) {
                return (volume, container)
            }
        }
        return nil
    }

    /// A volume by a command's target: its disk or its APFS volume UUID.
    public func volume(target: String) -> (volume: APFSVolume, container: APFSContainer)? {
        volume(device: target) ?? volume(uuid: target)
    }

    /// What `diskutil info` said of a disk.
    public func info(device: String) -> VolumeInfo? { infos.first { $0.device == device } }

    /// Each role's volume and plan.
    public func state(for role: VolumeRole) -> VolumeState { VolumePlanner.state(for: role, in: self) }
}
