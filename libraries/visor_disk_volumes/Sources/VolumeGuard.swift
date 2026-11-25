// The last check before diskutil runs as an administrator.

/// Checks commands against the disks as they are, just before they run:
/// only `apfs addVolume` of a missing role's volume, `mdutil -i off
/// /Volumes/Visor` on Visor's own volume (mounted there, or made by an
/// addVolume before it in the same run), and `chown <the user>:staff` and
/// `chmod 775` of a role's mount point, the volume made before them in the
/// same run (or, for Fix, an adopted one of Visor's own the caller names in
/// `fixing`), ever pass. No volume is ever deleted, erased or reformatted:
/// anything aimed at Sessions (by name, by mount point, by disk or by UUID)
/// says so, whoever built the command, and anything else is refused; and so
/// is any argument that's exactly `&&`.
public enum VolumeGuard {
    /// What joins commands in the administrator prompt's one shell
    /// (PrivilegeRoute's AppleScript passes it through unquoted): never an
    /// argument of a command, or the command after it would be a new one.
    public static let commandJoiner = "&&"

    /// The verbs that erase, delete or reformat: none is ever run, and one
    /// aimed at Sessions is refused as such.
    static let destructive: Set<String> = [
        "deleteVolume", "eraseVolume", "deleteContainer", "deleteVolumeGroup", "deleteSnapshot",
        "eraseDisk", "reformat", "partitionDisk", "zeroDisk", "randomDisk", "secureErase",
        "splitPartition", "mergePartitions", "resizeVolume", "resizeContainer", "convert", "decryptVolume",
    ]

    /// Throws unless every command may run now. `user`: the person running
    /// Visor Disk Utility, the only owner a mount point is given (nil: no
    /// chown at all). `fixing`: the adopted volumes whose mount points'
    /// owner and mode may be put right (Fix, on the card).
    public static func check(_ commands: [DiskCommand], against survey: DiskSurvey, user: String? = nil,
                             fixing: Set<VolumeRole> = []) throws {
        let sessions = survey.state(for: .sessions)
        // The roles an addVolume before it in this run makes.
        var made: Set<VolumeRole> = []
        if let joined = commands.first(where: { $0.arguments.contains(commandJoiner) }) {
            throw DiskVolumesError.notAllowed("\(joined.description) (an argument is exactly \(commandJoiner), "
                + "which would start another command in the administrator prompt's shell)")
        }
        for command in commands {
            let arguments = command.arguments
            if command.program == DiskCommand.mdutil {
                try checkSpotlightOff(arguments, survey: survey, made: made, command: command)
                continue
            }
            if command.program == DiskCommand.chown || command.program == DiskCommand.chmod {
                try checkOwnership(command, survey: survey, made: made, user: user, fixing: fixing)
                continue
            }
            guard command.program == DiskCommand.diskutil else { throw DiskVolumesError.notAllowed(command.description) }
            if let verb = arguments.firstIndex(where: destructive.contains) {
                for target in arguments[(verb + 1)...] where !target.hasPrefix("-") {
                    try refuseSessions(target, sessions: sessions, survey: survey, command: command)
                }
            }
            guard Array(arguments.prefix(2)) == ["apfs", "addVolume"] else { throw DiskVolumesError.notAllowed(command.description) }
            try checkAdd(arguments, survey: survey, command: command)
            if let role = VolumeRole.allCases.first(where: { $0.volumeName == arguments[4] }) { made.insert(role) }
        }
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

    private static func checkAdd(_ arguments: [String], survey: DiskSurvey, command: DiskCommand) throws {
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
        if exists {
            throw DiskVolumesError.wrongTarget("\(role.volumeName) already exists: it's adopted, never made twice.")
        }
    }
}
