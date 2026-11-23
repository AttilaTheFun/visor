// The last check before diskutil runs as an administrator.

/// Checks commands against the disks as they are, just before they run:
/// only `apfs addVolume` of a missing role's volume, `apfs deleteVolume` of
/// one of Visor's own volumes by its APFS volume UUID when that role is one
/// the caller asked to delete (`deleting`: none, unless Uninstall… was
/// asked to delete the volumes), `mdutil -i off /Volumes/Visor` on
/// Visor's own volume (mounted there, or made by an addVolume before it in
/// the same run), and `chown <the user>:staff` and `chmod 775` of a role's
/// mount point, the volume made before them in the same run (or, for Fix,
/// an adopted one of Visor's own the caller names in `fixing`), ever pass. Anything
/// that would erase or delete Sessions (by name, by mount point, by disk or
/// by UUID) throws, whoever built the command, unless Sessions itself is
/// asked for; and so does any argument that's exactly `&&`. A conversion's
/// commands (VolumeGuard+Conversion: `<Name>-new` added, the swap's and
/// unswap's renames, unmounts and mounts) pass only for a role named in
/// `converting`, and only exactly as ConversionPlanner plans that step
/// from the survey; a kept volume (`<Name>-old-ci`, `<Name>-cs-failed`) is
/// deleted only when its name is in `deletingKept`.
public enum VolumeGuard {
    /// What joins commands in the administrator prompt's one shell
    /// (PrivilegeRoute's AppleScript passes it through unquoted): never an
    /// argument of a command, or the command after it would be a new one.
    public static let commandJoiner = "&&"

    /// The verbs that erase, delete or reformat: never aimed at Sessions
    /// unless it's asked for, and of these only deleteVolume is run at all.
    static let destructive: Set<String> = [
        "deleteVolume", "eraseVolume", "deleteContainer", "deleteVolumeGroup", "deleteSnapshot",
        "eraseDisk", "reformat", "partitionDisk", "zeroDisk", "randomDisk", "secureErase",
        "splitPartition", "mergePartitions", "resizeVolume", "resizeContainer", "convert", "decryptVolume",
    ]

    /// Throws unless every command may run now. `recorded` is volumes.json
    /// as Visor Disk Utility last wrote it: its ownVolumes say which volume
    /// of a role's name is Visor's when it isn't mounted at the role's
    /// mount point (nil: only the one mounted there is). `deleting`: the
    /// roles whose volumes may be deleted (none, unless Uninstall… was
    /// asked to, with the volumes' names typed). `user`: the person running
    /// Visor Disk Utility, the only owner a mount point is given (nil: no
    /// chown at all). `fixing`: the adopted volumes whose mount points'
    /// owner and mode may be put right (Fix, on the card).
    /// `converting`: the roles whose conversion step this run is (Stage,
    /// Swap In, unswap). `deletingKept`: the kept volumes' names whose
    /// deletion was asked for, each typed.
    public static func check(_ commands: [DiskCommand], against survey: DiskSurvey, recorded: VolumesStatus? = nil,
                             deleting: Set<VolumeRole> = [], user: String? = nil, fixing: Set<VolumeRole> = [],
                             converting: [VolumeRole: ConversionStep] = [:], deletingKept: Set<String> = []) throws {
        let sessions = survey.state(for: .sessions)
        var deleted: Set<String> = []
        // The roles an addVolume before it in this run makes.
        var made: Set<VolumeRole> = []
        // The roles whose conversion step has been matched.
        var converted: Set<VolumeRole> = []
        if let joined = commands.first(where: { $0.arguments.contains(commandJoiner) }) {
            throw DiskVolumesError.notAllowed("\(joined.description) (an argument is exactly \(commandJoiner), "
                + "which would start another command in the administrator prompt's shell)")
        }
        var index = 0
        while index < commands.count {
            let command = commands[index]
            let arguments = command.arguments
            index += 1
            if isConversionCommand(command) {
                index += try matchConversion(commands, at: index - 1, survey: survey, converting: converting, used: &converted, user: user) - 1
                continue
            }
            if command.program == DiskCommand.mdutil {
                try checkSpotlightOff(arguments, survey: survey, made: made, command: command)
                continue
            }
            if command.program == DiskCommand.chown || command.program == DiskCommand.chmod {
                try checkOwnership(command, survey: survey, made: made, user: user, fixing: fixing)
                continue
            }
            guard command.program == DiskCommand.diskutil else { throw DiskVolumesError.notAllowed(command.description) }
            let isDelete = Array(arguments.prefix(2)) == ["apfs", "deleteVolume"]
            if let verb = arguments.firstIndex(where: destructive.contains), !(isDelete && deleting.contains(.sessions)) {
                for target in arguments[(verb + 1)...] where !target.hasPrefix("-") {
                    try refuseSessions(target, sessions: sessions, survey: survey, command: command)
                }
            }
            switch Array(arguments.prefix(2)) {
            case ["apfs", "addVolume"]:
                try checkAdd(arguments, survey: survey, deleted: deleted, command: command)
                if let role = VolumeRole.allCases.first(where: { $0.volumeName == arguments[4] }) { made.insert(role) }
            case ["apfs", "deleteVolume"]:
                guard arguments.count == 3 else { throw DiskVolumesError.notAllowed(command.description) }
                if let role = try checkDelete(arguments[2], survey: survey, recorded: recorded, deleting: deleting,
                                              deletingKept: deletingKept) {
                    deleted.insert(role.volumeName)
                }
            default:
                throw DiskVolumesError.notAllowed(command.description)
            }
        }
    }

    /// Throws unless the target is one of Visor's own volumes, of a role
    /// asked for, by its APFS volume UUID, in the survey made just now:
    /// named for its role, with no system role, and either mounted at the
    /// role's mount point or the one volumes.json recorded as Visor's (so a
    /// volume of Visor's that came to be mounted elsewhere is still
    /// deleted, and someone else's of the name mounted elsewhere never is).
    /// A disk (`disk3s8`) is refused: its number can change between this
    /// look and the command. The role deleted.
    private static func checkDelete(_ target: String, survey: DiskSurvey, recorded: VolumesStatus?,
                                    deleting: Set<VolumeRole>, deletingKept: Set<String>) throws -> VolumeRole? {
        guard DiskCommand.isVolumeUUID(target) else {
            throw DiskVolumesError.wrongTarget("\(target) isn't an APFS volume UUID: Visor's volumes are deleted by their UUIDs alone, "
                + "never by a disk number, which can change. Nothing was deleted.")
        }
        guard let (volume, _) = survey.volume(uuid: target) else {
            throw DiskVolumesError.wrongTarget("No APFS volume here has the UUID \(target) now. Nothing was deleted.")
        }
        if let kept = KeptVolume.found(in: survey).first(where: { $0.volume.uuid.caseInsensitiveCompare(target) == .orderedSame }) {
            try checkKeptDelete(kept, deletingKept: deletingKept)
            return nil
        }
        guard let role = VolumeRole.allCases.first(where: { $0.volumeName == volume.name }), volume.roles.isEmpty else {
            throw DiskVolumesError.wrongTarget("\(volume.device) (\(target)) is \(volume.name), not one of Visor's volumes. Nothing was deleted.")
        }
        guard deleting.contains(role) else {
            throw DiskVolumesError.wrongTarget("\(role.volumeName) is deleted only when its deletion is asked for, by name. Nothing was deleted.")
        }
        let mountPoint = survey.info(device: volume.device)?.mountPoint
        let isRecorded = recorded?.ownUUID(for: role).map { $0.caseInsensitiveCompare(volume.uuid) == .orderedSame } ?? false
        guard mountPoint == role.mountPoint || isRecorded else {
            let place = mountPoint.map { "is mounted at \($0), not \(role.mountPoint)," } ?? "isn't mounted,"
            throw DiskVolumesError.wrongTarget(
                "The volume named \(role.volumeName) (\(volume.device), \(volume.uuid)) \(place) "
                    + "and isn't the \(role.volumeName) recorded in volumes.json: it may not be Visor's, so nothing was deleted. "
                    + "If it is Visor's, mount it at \(role.mountPoint); if not, rename it, or delete it yourself in Disk Utility.")
        }
        return role
    }

    /// Throws unless it's exactly `mdutil -i off /Volumes/Visor`, and the
    /// volume there is Visor's own: in the survey, named Visor with no
    /// system role and mounted in place; or made by an addVolume before it
    /// in the same run. Never Sessions or Sources, which stay indexed, and
    /// never a folder that isn't a volume of Visor's.
    private static func checkSpotlightOff(_ arguments: [String], survey: DiskSurvey, made: Set<VolumeRole>,
                                          command: DiskCommand) throws {
        let role = VolumeRole.visor
        guard arguments == ["-i", "off", role.mountPoint] else { throw DiskVolumesError.notAllowed(command.description) }
        guard made.contains(role) || survey.state(for: role).inPlaceUUID != nil else {
            throw DiskVolumesError.wrongTarget("\(role.mountPoint) isn't Visor's own volume (named \(role.volumeName), mounted there): "
                + "Spotlight is left as it is.")
        }
    }

    /// Throws unless it's exactly `chown <user>:staff <mount point>` (the
    /// person running Visor Disk Utility) or `chmod 775 <mount point>`, of a
    /// role's mount point, its volume made by an addVolume before it in the
    /// same run, or (Fix) an adopted one the caller names in `fixing` that's
    /// Visor's own (named for its role, mounted in place). Never `-R`,
    /// never `/` or any other path, never another owner.
    private static func checkOwnership(_ command: DiskCommand, survey: DiskSurvey, made: Set<VolumeRole>, user: String?,
                                       fixing: Set<VolumeRole>) throws {
        let arguments = command.arguments
        guard arguments.count == 2, let role = VolumeRole.allCases.first(where: { $0.mountPoint == arguments[1] }) else {
            throw DiskVolumesError.notAllowed(command.description)
        }
        if command.program == DiskCommand.chown {
            guard let user, DiskCommand.isUserName(user), arguments[0] == user + ":staff" else {
                throw DiskVolumesError.notAllowed(command.description)
            }
        } else {
            guard arguments[0] == "775" else { throw DiskVolumesError.notAllowed(command.description) }
        }
        let adoptedOwn = fixing.contains(role) && survey.state(for: role).inPlaceUUID != nil
        guard made.contains(role) || adoptedOwn else {
            throw DiskVolumesError.wrongTarget("\(role.mountPoint) is \(role.volumeName)'s, made before Visor Disk Utility looked: "
                + "its owner is changed only by its Fix, never as it's adopted.")
        }
    }

    /// Throws if the target is Sessions: its disk or UUID, a volume named
    /// Sessions, whatever is mounted at /Volumes/Sessions, or that path
    /// itself.
    private static func refuseSessions(_ target: String, sessions: VolumeState, survey: DiskSurvey, command: DiskCommand) throws {
        let name = VolumeRole.sessions.volumeName
        let path = VolumeRole.sessions.mountPoint
        let device = survey.volume(target: target)?.volume.device ?? target
        let isSessions = device == sessions.volume?.device
            || target == path || target.hasPrefix(path + "/")
            || target.caseInsensitiveCompare(name) == .orderedSame
            || survey.volume(device: device)?.volume.name.caseInsensitiveCompare(name) == .orderedSame
            || survey.info(device: device)?.mountPoint == path
        if isSessions { throw DiskVolumesError.sessionsNeverErased(command.description) }
    }

    private static func checkAdd(_ arguments: [String], survey: DiskSurvey, deleted: Set<String>, command: DiskCommand) throws {
        guard arguments.count >= 5,
              let role = VolumeRole.allCases.first(where: { $0.volumeName == arguments[4] }),
              arguments[3] == role.personality else {
            throw DiskVolumesError.notAllowed(command.description)
        }
        let options = arguments.dropFirst(5)
        let allowed: Set<String> = ["-reserve", "-quota"]
        // Each option a reserve or quota, each value exact bytes (`20000000000b`,
        // ByteSize.argument's).
        for (index, option) in options.enumerated() {
            let valid = index % 2 == 0
                ? allowed.contains(option)
                : option.count > 1 && option.hasSuffix("b") && option.dropLast().allSatisfy { ("0"..."9").contains($0) }
            guard valid else { throw DiskVolumesError.notAllowed(command.description) }
        }
        guard options.count % 2 == 0 else { throw DiskVolumesError.notAllowed(command.description) }
        guard survey.containers.contains(where: { $0.reference == arguments[2] }) else {
            throw DiskVolumesError.wrongTarget("\(arguments[2]) isn't an APFS container here.")
        }
        let exists = survey.containers.flatMap(\.volumes).contains { $0.name == role.volumeName }
            || survey.infos.contains { $0.mountPoint == role.mountPoint }
        if exists, !deleted.contains(role.volumeName) {
            throw DiskVolumesError.wrongTarget("\(role.volumeName) already exists: it's adopted, never made twice.")
        }
    }
}
