// The last check before diskutil runs as an administrator.

/// Checks commands against the disks as they are, just before they run:
/// only `apfs addVolume` of a missing role's volume, and `apfs
/// deleteVolume` of the Containers volume, ever pass. Anything that would
/// erase or delete Sessions (by name, by mount point, or by disk) throws,
/// whoever built the command.
public enum VolumeGuard {
    /// The verbs that erase, delete or reformat: never aimed at Sessions,
    /// and of these only deleteVolume is run at all.
    static let destructive: Set<String> = [
        "deleteVolume", "eraseVolume", "deleteContainer", "deleteVolumeGroup", "deleteSnapshot",
        "eraseDisk", "reformat", "partitionDisk", "zeroDisk", "randomDisk", "secureErase",
        "splitPartition", "mergePartitions", "resizeVolume", "resizeContainer", "convert", "decryptVolume",
    ]

    public static func check(_ commands: [DiskCommand], against survey: DiskSurvey) throws {
        let sessions = survey.state(for: .sessions)
        var deleted: Set<String> = []
        for command in commands {
            let arguments = command.arguments
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
                let device = arguments[2]
                guard let (volume, _) = survey.volume(device: device) else {
                    throw DiskVolumesError.wrongTarget("\(device) isn't an APFS volume here; nothing was deleted.")
                }
                guard volume.name == VolumeRole.containers.volumeName, volume.roles.isEmpty else {
                    throw DiskVolumesError.wrongTarget("\(device) is \(volume.name), not Containers; nothing was deleted.")
                }
                deleted.insert(volume.name)
            default:
                throw DiskVolumesError.notAllowed(command.description)
            }
        }
    }

    /// Throws if the target is Sessions: its disk, a volume named Sessions,
    /// whatever is mounted at /Volumes/Sessions, or that path itself.
    private static func refuseSessions(_ target: String, sessions: VolumeState, survey: DiskSurvey, command: DiskCommand) throws {
        let name = VolumeRole.sessions.volumeName
        let path = VolumeRole.sessions.mountPoint
        let isSessions = target == sessions.volume?.device
            || target == path || target.hasPrefix(path + "/")
            || target.caseInsensitiveCompare(name) == .orderedSame
            || survey.volume(device: target)?.volume.name.caseInsensitiveCompare(name) == .orderedSame
            || survey.info(device: target)?.mountPoint == path
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
        for (index, option) in options.enumerated() where index % 2 == 0 {
            guard allowed.contains(option) else { throw DiskVolumesError.notAllowed(command.description) }
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
