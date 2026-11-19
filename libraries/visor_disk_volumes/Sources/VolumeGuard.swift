// The last check before diskutil runs as an administrator.

/// Checks commands against the disks as they are, just before they run:
/// only `apfs addVolume` of a missing role's volume, and `apfs
/// deleteVolume` of Visor's own Containers volume by its APFS volume UUID,
/// ever pass. Anything that would erase or delete Sessions (by name, by
/// mount point, by disk or by UUID) throws, whoever built the command, and
/// so does any argument that's exactly `&&`.
public enum VolumeGuard {
    /// What joins commands in the administrator prompt's one shell
    /// (PrivilegeRoute's AppleScript passes it through unquoted): never an
    /// argument of a command, or the command after it would be a new one.
    public static let commandJoiner = "&&"

    /// The verbs that erase, delete or reformat: never aimed at Sessions,
    /// and of these only deleteVolume is run at all.
    static let destructive: Set<String> = [
        "deleteVolume", "eraseVolume", "deleteContainer", "deleteVolumeGroup", "deleteSnapshot",
        "eraseDisk", "reformat", "partitionDisk", "zeroDisk", "randomDisk", "secureErase",
        "splitPartition", "mergePartitions", "resizeVolume", "resizeContainer", "convert", "decryptVolume",
    ]

    /// Throws unless every command may run now. `recorded` is volumes.json
    /// as Visor Disk Utility last wrote it: its ownVolumes say which
    /// Containers is Visor's when it isn't mounted at /Volumes/Containers
    /// (nil: only the one mounted there is).
    public static func check(_ commands: [DiskCommand], against survey: DiskSurvey, recorded: VolumesStatus? = nil) throws {
        let sessions = survey.state(for: .sessions)
        var deleted: Set<String> = []
        for command in commands {
            let arguments = command.arguments
            if arguments.contains(commandJoiner) {
                throw DiskVolumesError.notAllowed("\(command.description) (an argument is exactly \(commandJoiner), "
                    + "which would start another command in the administrator prompt's shell)")
            }
            guard command.argv.first == DiskCommand.diskutil else { throw DiskVolumesError.notAllowed(command.description) }
            if let verb = arguments.firstIndex(where: destructive.contains) {
                for target in arguments[(verb + 1)...] where !target.hasPrefix("-") {
                    try refuseSessions(target, sessions: sessions, survey: survey, command: command)
                }
            }
            switch Array(arguments.prefix(2)) {
            case ["apfs", "addVolume"]:
                try checkAdd(arguments, survey: survey, deleted: deleted, command: command)
            case ["apfs", "deleteVolume"]:
                guard arguments.count == 3 else { throw DiskVolumesError.notAllowed(command.description) }
                try checkDelete(arguments[2], survey: survey, recorded: recorded)
                deleted.insert(VolumeRole.containers.volumeName)
            default:
                throw DiskVolumesError.notAllowed(command.description)
            }
        }
    }

    /// Throws unless the target is Visor's own Containers, by its APFS
    /// volume UUID, in the survey made just now: named Containers, with no
    /// system role, and either mounted at /Volumes/Containers or the one
    /// volumes.json recorded as Visor's (so a volume of Visor's that came
    /// to be mounted elsewhere is still erased, and someone else's
    /// Containers mounted elsewhere never is). A disk (`disk3s8`) is
    /// refused: its number can change between this look and the command.
    private static func checkDelete(_ target: String, survey: DiskSurvey, recorded: VolumesStatus?) throws {
        let role = VolumeRole.containers
        guard DiskCommand.isVolumeUUID(target) else {
            throw DiskVolumesError.wrongTarget("\(target) isn't an APFS volume UUID: \(role.volumeName) is deleted by its UUID alone, "
                + "never by a disk number, which can change. Nothing was deleted.")
        }
        guard let (volume, _) = survey.volume(uuid: target) else {
            throw DiskVolumesError.wrongTarget("No APFS volume here has the UUID \(target) now. Nothing was deleted.")
        }
        guard volume.name == role.volumeName, volume.roles.isEmpty else {
            throw DiskVolumesError.wrongTarget("\(volume.device) (\(target)) is \(volume.name), not \(role.volumeName). Nothing was deleted.")
        }
        let mountPoint = survey.info(device: volume.device)?.mountPoint
        let isRecorded = recorded?.ownUUID(for: role).map { $0.caseInsensitiveCompare(volume.uuid) == .orderedSame } ?? false
        guard mountPoint == role.mountPoint || isRecorded else {
            let place = mountPoint.map { "is mounted at \($0)" } ?? "isn't mounted"
            throw DiskVolumesError.wrongTarget(
                "The volume named \(role.volumeName) (\(volume.device), \(volume.uuid)) \(place), not at \(role.mountPoint), "
                    + "and isn't the \(role.volumeName) recorded in volumes.json: it may not be Visor's, so nothing was deleted. "
                    + "If it is Visor's, mount it at \(role.mountPoint); if not, rename it, or delete it yourself in Disk Utility.")
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
