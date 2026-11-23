// Adopt or create: the decision for each volume.

/// Decides, for each role, whether the volume is adopted as it is, made,
/// or left for a person to sort out. An existing volume is never
/// reformatted, whatever its case.
public enum VolumePlanner {
    /// The role's volume and plan in the survey:
    /// 1. a volume mounted at its mount point is adopted (if it's APFS);
    /// 2. else one volume of its name, wherever it's mounted, is adopted;
    ///    several are left for a person;
    /// 3. else, a folder at the mount point stops it being made;
    /// 4. else it's made in the boot container.
    public static func state(for role: VolumeRole, in survey: DiskSurvey) -> VolumeState {
        if let mounted = survey.infos.first(where: { $0.mountPoint == role.mountPoint }) {
            return adopt(role, info: mounted, in: survey)
        }
        let named = survey.containers.flatMap(\.volumes).filter { $0.name == role.volumeName }
        if named.count > 1 {
            return VolumeState(role: role, plan: .blocked(
                "\(named.count) volumes are named \(role.volumeName) (\(named.map(\.device).joined(separator: ", "))), "
                    + "and none is mounted at \(role.mountPoint). Mount the right one there, or rename the others, in Disk Utility."))
        }
        if let volume = named.first {
            let info = survey.info(device: volume.device)
            return adopt(role, info: info ?? VolumeInfo(device: volume.device, volumeName: volume.name, mountPoint: nil,
                                                        filesystemName: "", containerReference: nil),
                         in: survey)
        }
        if survey.foldersInTheWay.contains(role.mountPoint) {
            return VolumeState(role: role, plan: .blocked(
                "\(role.mountPoint) is a folder, not a volume: a new volume would be mounted beside it. Move the folder away first."))
        }
        guard let boot = survey.containers.first(where: { $0.reference == survey.bootContainer }) else {
            return VolumeState(role: role, plan: .blocked("The boot disk's APFS container (\(survey.bootContainer)) wasn't found."))
        }
        return VolumeState(role: role, plan: .create(container: boot.reference), container: boot)
    }

    private static func adopt(_ role: VolumeRole, info: VolumeInfo, in survey: DiskSurvey) -> VolumeState {
        guard let (volume, container) = survey.volume(device: info.device) else {
            let kind = info.filesystemName.isEmpty ? info.filesystemType : info.filesystemName
            return VolumeState(role: role, plan: .blocked(
                "\(role.mountPoint) is a \(kind) volume (\(info.device)), not APFS. Visor Disk Utility leaves it alone."),
                info: info)
        }
        var notes: [String] = []
        if volume.name != role.volumeName {
            notes.append("It's named \(volume.name), mounted at \(role.mountPoint).")
        }
        switch info.mountPoint {
        case role.mountPoint?: break
        case let elsewhere?: notes.append("It's mounted at \(elsewhere), not \(role.mountPoint), where Visor looks for it.")
        case nil: notes.append("It isn't mounted. Mount it (Disk Utility, or `diskutil mount \(volume.device)`) so Visor finds it at \(role.mountPoint).")
        }
        if !info.filesystemName.isEmpty, info.isCaseSensitive != role.wantsCaseSensitive {
            notes.append(caseNote(role))
        }
        return VolumeState(role: role, plan: .adopt, volume: volume, info: info, container: container, notes: notes,
                           measuredFree: info.mountPoint.flatMap { survey.freeSpace[$0] })
    }

    /// What a case-insensitive volume means for the role.
    static func caseNote(_ role: VolumeRole) -> String {
        let what = "It's case-insensitive APFS: names differing only in case (Makefile and makefile, Foo.h and foo.h) "
            + "are one file here, so a Linux checkout or build in the container can collide or fail where a Linux disk wouldn't."
        guard role.isConvertible else {
            return what + " It's adopted as it is, never reformatted. To change it, move what's on it elsewhere, then remake the volume yourself."
        }
        return what + " It's adopted as it is, never reformatted. To change it, convert it below (Stage, a checked copy, "
            + "Swap In: docs/volume-conversion.md)."
    }
}
