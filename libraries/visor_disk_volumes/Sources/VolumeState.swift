// A role's volume as it is now, and what's to be done.

/// One of the three volumes: found or not, its plan, and what it holds.
public struct VolumeState: Equatable, Sendable {
    public var role: VolumeRole
    public var plan: VolumePlan
    /// The volume, when there is one.
    public var volume: APFSVolume?
    public var info: VolumeInfo?
    /// The container it's in, or the one it would be made in.
    public var container: APFSContainer?
    /// What a person should know about it (its case, where it's mounted).
    public var notes: [String]
    /// What its filesystem says it can still take, when it's mounted.
    public var measuredFree: Int64?

    public init(role: VolumeRole, plan: VolumePlan, volume: APFSVolume? = nil, info: VolumeInfo? = nil,
                container: APFSContainer? = nil, notes: [String] = [], measuredFree: Int64? = nil) {
        self.role = role
        self.plan = plan
        self.volume = volume
        self.info = info
        self.container = container
        self.notes = notes
        self.measuredFree = measuredFree
    }

    public var exists: Bool { volume != nil }

    /// Where it's mounted, or where it will be.
    public var path: String { info?.mountPoint ?? role.mountPoint }

    /// Whether it's mounted where Visor looks for it.
    public var isMountedInPlace: Bool { info?.mountPoint == role.mountPoint }

    /// Its personality (`Case-sensitive APFS`); the one it will have, when
    /// it's to be made.
    public var format: String { info?.filesystemName ?? role.personality }

    public var isCaseSensitive: Bool? { info.map(\.isCaseSensitive) }

    /// Whether what APFS lists as its use is its reserve: its files take
    /// that much or less.
    public var isWithinReserve: Bool {
        guard let volume else { return false }
        return volume.reserve > 0 && volume.used <= volume.reserve
    }

    /// Its use for a person: "12.5 GB", or "within its 5 GB reserve".
    public var usedDescription: String? {
        guard let volume else { return nil }
        return isWithinReserve ? "within its \(ByteSize.describe(volume.reserve)) reserve" : ByteSize.describe(volume.used)
    }

    /// Bytes it may still take: what its filesystem says when it's mounted;
    /// else its container's free space, plus what's left of its own
    /// reserve, up to its quota. (APFS lists a volume's use as at least its
    /// reserve, so an unmounted volume's unused reserve isn't counted.)
    public var available: Int64? {
        if let measuredFree { return measuredFree }
        guard let container else { return nil }
        guard let volume else { return container.free }
        var room = container.free + max(0, volume.reserve - volume.used)
        if volume.quota > 0 { room = min(room, max(0, volume.quota - volume.used)) }
        return room
    }

    /// The commands that make it: `diskutil apfs addVolume` in the boot
    /// container, case-sensitive, with its reserve and quota (0: none); its
    /// mount point given to `user` (`chown <user>:staff`, `chmod 775`: as an
    /// administrator made it, it's root's); and, for Visor, Spotlight turned
    /// off on it (VolumeExclusions). All in the same administrator prompt.
    public func createCommands(reserve: Int64, quota: Int64, user: String) throws -> [DiskCommand] {
        guard case let .create(container) = plan else {
            throw DiskVolumesError.blocked("\(role.volumeName) already exists or can't be made here; it's never made twice.")
        }
        let made = [try DiskCommand.addVolume(role, container: container, reserve: reserve, quota: quota)]
            + (try DiskCommand.ownership(role, user: user))
        return role == .visor ? made + [try DiskCommand.spotlightOff(role)] : made
    }

    /// The commands that give an adopted volume's mount point to `user`
    /// (its Fix, on the card, when it isn't theirs): Visor's own alone
    /// (named for its role, mounted in place). VolumeGuard lets them run
    /// only with the role named in its `fixing`.
    public func ownershipCommands(user: String) throws -> [DiskCommand] {
        guard inPlaceUUID != nil else {
            throw DiskVolumesError.blocked("\(role.mountPoint) isn't \(role.volumeName) as Visor Disk Utility makes it: its owner is left as it is.")
        }
        return try DiskCommand.ownership(role, user: user)
    }

    /// The commands that put back what an adopted volume should have: for
    /// Visor's own (mounted in place), Spotlight turned off when it's found
    /// indexing (`exclusions`); nothing for Sessions and Sources, which are
    /// backed up and indexed as any folder of the person's is. Time
    /// Machine's exclusion is the person's to make (VolumeExclusions).
    public func exclusionCommands(_ exclusions: VolumeExclusions) throws -> [DiskCommand] {
        guard role == .visor, inPlaceUUID != nil, exclusions.spotlightIndexed != false else { return [] }
        return [try DiskCommand.spotlightOff(role)]
    }

    /// Its APFS volume UUID when it's Visor's own as found now: named for
    /// its role, with no system role, mounted at its mount point (as Visor
    /// Disk Utility makes it). volumes.json keeps it (VolumesStatus.ownVolumes):
    /// a volume of the name mounted elsewhere is Visor's only if its UUID is
    /// the one kept.
    public var inPlaceUUID: String? {
        guard let volume, isMountedInPlace, volume.name == role.volumeName, volume.roles.isEmpty,
              DiskCommand.isVolumeUUID(volume.uuid) else { return nil }
        return volume.uuid
    }

    /// Its line in volumes.json; nil when there's no volume.
    public var record: VolumeRecord? {
        guard let volume else { return nil }
        return VolumeRecord(role: role, name: volume.name, uuid: volume.uuid.isEmpty ? nil : volume.uuid,
                            path: info?.mountPoint, device: volume.device,
                            format: info?.filesystemName ?? "", caseSensitive: info?.isCaseSensitive,
                            used: volume.used, quota: volume.quota, reserve: volume.reserve, available: available)
    }
}
