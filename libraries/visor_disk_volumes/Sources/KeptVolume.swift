// A volume a conversion left beside a role's: the old case-insensitive one
// kept for rollback (`Sessions-old-ci`), or a copy unswap took back out
// (`Sessions-cs-failed`). Neither is ever used by Visor; each is deleted
// only when a person asks, its name typed.

public struct KeptVolume: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// The role's volume as it was before the swap (`<Name>-old-ci`).
        case rollback
        /// A converted copy unswap took out (`<Name>-cs-failed`).
        case failed
    }

    public var role: VolumeRole
    public var kind: Kind
    public var volume: APFSVolume
    /// What `diskutil info` said of it, if it was asked.
    public var info: VolumeInfo?

    public init(role: VolumeRole, kind: Kind, volume: APFSVolume, info: VolumeInfo? = nil) {
        self.role = role
        self.kind = kind
        self.volume = volume
        self.info = info
    }

    public var id: String { volume.uuid.isEmpty ? volume.device : volume.uuid }
    public var name: String { volume.name }

    /// Where it's mounted; nil when it isn't (as a swap leaves it).
    public var mountPoint: String? { info?.mountPoint }

    /// What it is, in a line: "Sessions-old-ci (disk3s7): kept for rollback".
    public var summary: String {
        let what = switch kind {
        case .rollback: "kept for rollback (\(role.volumeName) as it was, case-insensitive)"
        case .failed: "the case-sensitive copy taken out by unswap"
        }
        let place = mountPoint.map { "mounted at \($0)" } ?? "not mounted"
        return "\(name) (\(volume.device), \(place)): \(what)"
    }

    /// What's typed to delete it: "delete Sessions-old-ci".
    public var confirmation: String { "delete " + name }

    /// Whether `typed` is that, its spaces at either end aside.
    public func matches(_ typed: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines) == confirmation
    }

    /// The command that deletes it, by its APFS volume UUID, never its disk.
    /// VolumeGuard passes it only with its name in `deletingKept`.
    public func deleteCommand() throws -> DiskCommand {
        guard DiskCommand.isVolumeUUID(volume.uuid) else {
            throw DiskVolumesError.blocked("\(name) has no APFS volume UUID: it's deleted by its UUID alone.")
        }
        return DiskCommand(arguments: ["apfs", "deleteVolume", volume.uuid])
    }

    /// The kept volumes in the survey: named `<Name>-old-ci` or
    /// `<Name>-cs-failed` for Sessions or Sources, with no system role.
    public static func found(in survey: DiskSurvey) -> [KeptVolume] {
        var kept: [KeptVolume] = []
        for volume in survey.containers.flatMap(\.volumes) where volume.roles.isEmpty {
            for role in VolumeRole.convertible {
                let kind: Kind? = volume.name == role.keptName ? .rollback : volume.name == role.failedName ? .failed : nil
                if let kind { kept.append(KeptVolume(role: role, kind: kind, volume: volume, info: survey.info(device: volume.device))) }
            }
        }
        return kept
    }

    /// The kept volume of this name, if there's exactly one.
    public static func named(_ name: String, in survey: DiskSurvey) -> KeptVolume? {
        let those = found(in: survey).filter { $0.name == name }
        return those.count == 1 ? those[0] : nil
    }
}
