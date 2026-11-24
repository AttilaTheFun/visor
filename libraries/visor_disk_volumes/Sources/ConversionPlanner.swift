// A conversion of Sessions or Sources from case-insensitive to
// case-sensitive APFS (docs/volume-conversion.md), planned from the disks
// as they are: Stage makes `<Name>-new` beside the role's volume,
// copy-staged copies onto it and leaves the marker, Swap In renames the old
// one away and the copy into its place, and unswap puts the old one back.
// Each step is refused unless the disks are as it expects; VolumeGuard
// plans each again just before its commands run, and passes them only when
// they're the same.

import Foundation

public enum ConversionPlanner {
    /// The role's volume as a conversion takes it: Visor's own, in place
    /// (named for its role, mounted at its mount point, no system role), APFS.
    public static func source(_ role: VolumeRole, in survey: DiskSurvey) throws -> (volume: APFSVolume, info: VolumeInfo, container: APFSContainer) {
        guard role.isConvertible else {
            throw DiskVolumesError.blocked("\(role.volumeName) isn't converted: only Sessions and Sources are, Visor's own is made case-sensitive.")
        }
        let state = survey.state(for: role)
        if case let .blocked(why) = state.plan { throw DiskVolumesError.blocked("\(role.volumeName) can't be converted: \(why)") }
        guard case .adopt = state.plan, state.inPlaceUUID != nil, let volume = state.volume, let info = state.info, info.isAPFS,
              let container = state.container else {
            throw DiskVolumesError.blocked("There's no \(role.volumeName) volume mounted at \(role.mountPoint) to convert.")
        }
        return (volume, info, container)
    }

    /// The volumes named `<Name>-new`, wherever they are.
    public static func stagedVolumes(_ role: VolumeRole, in survey: DiskSurvey) -> [APFSVolume] {
        survey.containers.flatMap(\.volumes).filter { $0.name == role.stagedName }
    }

    /// The commands that stage the copy: `diskutil apfs addVolume <the
    /// role's container> "Case-sensitive APFS" <Name>-new`, with the role
    /// volume's own reserve and quota (none: none), then its mount point
    /// given to `user` (`chown <user>:staff`, `chmod 775`), as create does.
    public static func stageCommands(_ role: VolumeRole, in survey: DiskSurvey, user: String) throws -> [DiskCommand] {
        let source = try checkStage(role, in: survey)
        guard DiskCommand.isUserName(user) else { throw DiskVolumesError.blocked("\(user) isn't a user's name.") }
        var arguments = ["apfs", "addVolume", source.container.reference, role.personality, role.stagedName]
        if source.volume.reserve > 0 { arguments += ["-reserve", ByteSize.argument(source.volume.reserve)] }
        if source.volume.quota > 0 { arguments += ["-quota", ByteSize.argument(source.volume.quota)] }
        return [DiskCommand(arguments: arguments),
                DiskCommand(program: DiskCommand.chown, arguments: [user + ":staff", role.stagedMountPoint]),
                DiskCommand(program: DiskCommand.chmod, arguments: ["775", role.stagedMountPoint])]
    }

    /// What must stay free in the container once a copy onto a staged
    /// volume with no quota of its own is made: a tenth of the free space,
    /// at least 20 GB. (The copy gets its source's quota, and none when the
    /// source has none: a quota can't be changed or removed once a volume
    /// is made, by diskutil or any tool, and the copy becomes the volume
    /// Visor uses. So it isn't bounded by one; copy-staged refuses a copy
    /// that would leave less than this free instead.)
    public static func keptFree(containerFree: Int64) -> Int64 {
        max(20 * ByteSize.gigabyte, containerFree / 10)
    }

    /// Throws unless Stage may run for the role: its volume there,
    /// case-insensitive, no `<Name>-new` or `<Name>-old-ci` yet, nothing at
    /// `/Volumes/<Name>-new`, and room in its container for a copy.
    @discardableResult
    static func checkStage(_ role: VolumeRole, in survey: DiskSurvey) throws -> (volume: APFSVolume, info: VolumeInfo, container: APFSContainer) {
        let source = try source(role, in: survey)
        guard !source.info.isCaseSensitive else {
            throw DiskVolumesError.blocked("\(role.volumeName) is \(source.info.filesystemName) already: nothing to convert.")
        }
        let staged = stagedVolumes(role, in: survey)
        guard staged.isEmpty else {
            throw DiskVolumesError.blocked("\(role.stagedName) exists already (\(staged.map(\.device).joined(separator: ", "))): it's staged. "
                + "Copy onto it with copy-staged \(role.rawValue), or delete it in Disk Utility to stage it again.")
        }
        if let kept = KeptVolume.found(in: survey).first(where: { $0.role == role }) {
            throw DiskVolumesError.blocked("\(kept.name) exists already (\(kept.volume.device)), from an earlier conversion: "
                + "delete it (Delete…, or delete-kept \(kept.name)) before staging again.")
        }
        if survey.foldersInTheWay.contains(role.stagedMountPoint) || survey.infos.contains(where: { $0.mountPoint == role.stagedMountPoint }) {
            throw DiskVolumesError.blocked("\(role.stagedMountPoint) is taken already (a folder, or another volume): "
                + "\(role.stagedName) would be mounted beside it. Move it away first.")
        }
        // What it holds, as APFS counts it (at least its reserve), and a
        // gigabyte to spare: a first estimate. Clones and hard links split
        // between root entries take more; copy-staged counts them before it
        // copies (ConversionCopy.bytesNeeded), and the quota bounds them.
        let needed = source.volume.used + ByteSize.gigabyte
        guard source.container.free >= needed else {
            throw DiskVolumesError.blocked("\(source.container.reference) has \(ByteSize.describe(source.container.free)) free; "
                + "a copy of \(role.volumeName) needs about \(ByteSize.describe(needed)).")
        }
        if source.volume.quota > 0, source.volume.reserve > source.volume.quota {
            throw DiskVolumesError.blocked("\(role.volumeName)'s reserve is more than its quota: diskutil wouldn't make the copy so.")
        }
        return source
    }

    /// The staged copy as copy-staged and Swap In take it: the one volume
    /// named `<Name>-new`, mounted at `/Volumes/<Name>-new`,
    /// case-sensitive, in the role's volume's container.
    public static func staged(_ role: VolumeRole, in survey: DiskSurvey) throws -> (volume: APFSVolume, info: VolumeInfo) {
        let source = try source(role, in: survey)
        let staged = stagedVolumes(role, in: survey)
        guard staged.count == 1 else {
            throw DiskVolumesError.blocked(staged.isEmpty
                ? "There's no \(role.stagedName): stage it first (Stage, or stage \(role.rawValue))."
                : "\(staged.count) volumes are named \(role.stagedName) (\(staged.map(\.device).joined(separator: ", "))): rename or delete the others.")
        }
        let volume = staged[0]
        guard let info = survey.info(device: volume.device), info.mountPoint == role.stagedMountPoint else {
            throw DiskVolumesError.blocked("\(role.stagedName) (\(volume.device)) isn't mounted at \(role.stagedMountPoint): "
                + "mount it there (diskutil mount \(volume.device)).")
        }
        guard info.isCaseSensitive else {
            throw DiskVolumesError.blocked("\(role.stagedName) is \(info.filesystemName.isEmpty ? "not APFS" : info.filesystemName), not case-sensitive: "
                + "delete it and stage again.")
        }
        guard survey.volume(device: volume.device)?.container.reference == source.container.reference, volume.roles.isEmpty,
              DiskCommand.isVolumeUUID(volume.uuid) else {
            throw DiskVolumesError.blocked("\(role.stagedName) (\(volume.device)) isn't the staged copy of \(role.volumeName): "
                + "it's in another APFS container, or has a system role.")
        }
        return (volume, info)
    }

    /// The two volumes copy-staged copies between: the role's own,
    /// case-insensitive, and its staged copy.
    public static func copyPair(_ role: VolumeRole, in survey: DiskSurvey) throws -> (source: APFSVolume, staged: APFSVolume) {
        let source = try source(role, in: survey)
        guard !source.info.isCaseSensitive else {
            throw DiskVolumesError.blocked("\(role.volumeName) is \(source.info.filesystemName) already: nothing to convert.")
        }
        return (source.volume, try staged(role, in: survey).volume)
    }

    /// The commands that swap the verified copy in, each by its disk:
    /// the old volume renamed `<Name>-old-ci` and unmounted (kept for
    /// rollback), the copy renamed `<Name>`, unmounted and mounted again,
    /// at `/Volumes/<Name>`. Refused without a marker that names these two
    /// volumes and is at most two hours old (`now`).
    public static func swapCommands(_ role: VolumeRole, in survey: DiskSurvey, marker: ConversionMarker?, now: Date = Date()) throws -> [DiskCommand] {
        let named = survey.containers.flatMap(\.volumes).filter { $0.name == role.volumeName }
        // A swap that stopped after its first rename: the old volume is
        // `<Name>-old-ci` and nothing is `<Name>`. It holds everything, so
        // it's never to be deleted: unswap names it back (the Mini's window,
        // 24 Nov, where the refusal below would have said to delete it).
        if named.isEmpty, let old = KeptVolume.found(in: survey).first(where: { $0.role == role && $0.kind == .rollback }) {
            throw DiskVolumesError.blocked("A Swap In of \(role.volumeName) stopped part-way: \(old.name) (\(old.volume.device)) is the old "
                + "\(role.volumeName), renamed, and no volume is named \(role.volumeName). Don't delete it: run `unswap \(role.rawValue)` "
                + "to name it back, then Swap In again.")
        }
        let pair = try copyPair(role, in: survey)
        guard named.count == 1 else {
            throw DiskVolumesError.blocked("\(named.count) volumes are named \(role.volumeName): rename the others before swapping.")
        }
        if let kept = KeptVolume.found(in: survey).first(where: { $0.role == role }) {
            throw DiskVolumesError.blocked("\(kept.name) exists already (\(kept.volume.device)): delete it before swapping.")
        }
        guard let marker else {
            throw DiskVolumesError.blocked("\(role.stagedName) has no \(ConversionMarker.fileName): it hasn't been copied and verified. "
                + "Run copy-staged \(role.rawValue) first.")
        }
        try marker.check(role: role, sourceUUID: pair.source.uuid, newUUID: pair.staged.uuid, now: now)
        return [try DiskCommand.rename(device: pair.source.device, to: role.keptName),
                try DiskCommand.unmount(device: pair.source.device),
                try DiskCommand.rename(device: pair.staged.device, to: role.volumeName),
                try DiskCommand.unmount(device: pair.staged.device),
                try DiskCommand.mount(device: pair.staged.device)]
    }

    /// The verb of Visor Disk Utility's own command that checks, as root,
    /// in the administrator prompt's shell just before the first rename,
    /// that nothing has changed since the person's checks and nothing is
    /// open (DiskTool.conversionCheck); run from a verified root-owned copy
    /// of the app (ConversionChecker).
    public static let checkVerb = "conversion-check"

    /// The check that comes first in Swap In's prompt: for each role, the
    /// sha256 of its marker's file, which the check reads again, with its
    /// UUIDs, age and the source's listing.
    public static func swapCheck(checker: ConversionChecker, markers: [(role: VolumeRole, digest: String)]) -> DiskCommand {
        checker.command([checkVerb, "swap"] + markers.flatMap { [$0.role.rawValue, $0.digest] })
    }

    /// The check that comes first in unswap's prompt: nothing open on the
    /// volumes, and Visor stopped.
    public static func unswapCheck(checker: ConversionChecker, roles: [VolumeRole]) -> DiskCommand {
        checker.command([checkVerb, "unswap"] + roles.map(\.rawValue))
    }

    /// The commands that undo a swap, if the old volume is still there
    /// (`<Name>-old-ci`, found by its name): the converted `<Name>` at the
    /// mount point, if there's one, renamed `<Name>-cs-failed` and
    /// unmounted; the old one mounted (if it isn't), renamed `<Name>`,
    /// unmounted and mounted again at `/Volumes/<Name>`. Each by its disk.
    public static func unswapCommands(_ role: VolumeRole, in survey: DiskSurvey) throws -> [DiskCommand] {
        guard role.isConvertible else { throw DiskVolumesError.blocked("Only Sessions and Sources are converted.") }
        let kept = KeptVolume.found(in: survey).filter { $0.role == role && $0.kind == .rollback }
        guard kept.count == 1 else {
            throw DiskVolumesError.blocked(kept.isEmpty
                ? "There's no \(role.keptName) to put back: it was deleted, or \(role.volumeName) was never swapped."
                : "\(kept.count) volumes are named \(role.keptName): rename the others first.")
        }
        if let failed = KeptVolume.found(in: survey).first(where: { $0.role == role && $0.kind == .failed }) {
            throw DiskVolumesError.blocked("\(failed.name) exists already (\(failed.volume.device)): delete it before unswapping again.")
        }
        let named = survey.containers.flatMap(\.volumes).filter { $0.name == role.volumeName }
        let old = kept[0]
        // A swap stopped after its first rename: the old volume, renamed,
        // still mounted where Visor looks. Named back, and mounted afresh.
        if survey.infos.first(where: { $0.mountPoint == role.mountPoint })?.device == old.volume.device {
            guard named.isEmpty else {
                throw DiskVolumesError.blocked("A volume named \(role.volumeName) exists beside \(old.name) at \(role.mountPoint): rename it first.")
            }
            return [try DiskCommand.rename(device: old.volume.device, to: role.volumeName),
                    try DiskCommand.unmount(device: old.volume.device),
                    try DiskCommand.mount(device: old.volume.device)]
        }
        var commands: [DiskCommand] = []
        if let info = survey.infos.first(where: { $0.mountPoint == role.mountPoint }) {
            guard let current = survey.volume(device: info.device)?.volume, current.name == role.volumeName, named.count == 1,
                  current.roles.isEmpty else {
                throw DiskVolumesError.blocked("\(role.mountPoint) is \(info.volumeName) (\(info.device)), not the converted \(role.volumeName): "
                    + "unswap leaves it alone.")
            }
            guard info.isCaseSensitive else {
                throw DiskVolumesError.blocked("\(role.volumeName) at \(role.mountPoint) is case-insensitive: it isn't a converted copy, "
                    + "so there's nothing to undo.")
            }
            commands += [try DiskCommand.rename(device: current.device, to: role.failedName), try DiskCommand.unmount(device: current.device)]
        } else if !named.isEmpty {
            throw DiskVolumesError.blocked("A volume named \(role.volumeName) (\(named.map(\.device).joined(separator: ", "))) isn't mounted at "
                + "\(role.mountPoint): mount or rename it first.")
        }
        if old.mountPoint == nil { commands.append(try DiskCommand.mount(device: old.volume.device)) }
        commands += [try DiskCommand.rename(device: old.volume.device, to: role.volumeName),
                     try DiskCommand.unmount(device: old.volume.device),
                     try DiskCommand.mount(device: old.volume.device)]
        return commands
    }

    /// Why unswap wants `--force`, or nil: the converted volume now at the
    /// role's mount point (`uuid`, its `listing` now) changed since Swap In
    /// left it (`note`), or there's no note of it. Unswap brings back the
    /// old volume as it was at the swap; what was written on the converted
    /// one since stays there, renamed `<Name>-cs-failed`.
    public static func unswapWarning(_ role: VolumeRole, note: ConversionNote?, uuid: String, listing: String) -> String? {
        let why: String
        if let note, note.newUUID.caseInsensitiveCompare(uuid) == .orderedSame {
            guard note.listingSHA256 != listing else { return nil }
            why = "\(role.volumeName) has changed since it was swapped in (\(ConversionMarker.describe(note.swapped)))"
        } else {
            why = "there's no note of when \(role.volumeName) (\(uuid)) was swapped in, so whether it changed since can't be told"
        }
        return why + ": unswap brings back \(role.keptName) as it was at the swap, and whatever was written on \(role.volumeName) since "
            + "stays on \(role.failedName) (unmounted), not on the volume Visor uses. Copy out what you need from it after, "
            + "or run unswap \(role.rawValue) --force to do it anyway."
    }

    /// Where the role's conversion stands, for the window and `status`.
    /// `marker`: the staged copy's marker as read (nil: none);
    /// `markerError`: why it couldn't be read, if it couldn't.
    public static func status(_ role: VolumeRole, in survey: DiskSurvey, marker: ConversionMarker?, markerError: String? = nil,
                              now: Date = Date()) -> ConversionStatus {
        let kept = KeptVolume.found(in: survey).filter { $0.role == role }
        let staged = stagedVolumes(role, in: survey).first
        func status(_ phase: ConversionStatus.Phase) -> ConversionStatus {
            ConversionStatus(role: role, phase: phase, staged: staged, kept: kept)
        }
        let source: (volume: APFSVolume, info: VolumeInfo, container: APFSContainer)
        do {
            source = try self.source(role, in: survey)
        } catch {
            return status(.unavailable("\(error)"))
        }
        if source.info.isCaseSensitive { return status(.converted) }
        guard staged != nil else {
            do {
                try checkStage(role, in: survey)
                return status(.ready)
            } catch {
                return status(.unavailable("\(error)"))
            }
        }
        do {
            let copy = try self.staged(role, in: survey)
            guard let marker else { return status(.staged(markerError.map { .refused($0) } ?? .notCopied)) }
            try marker.check(role: role, sourceUUID: source.volume.uuid, newUUID: copy.volume.uuid, now: now)
            return status(.staged(.verified(marker)))
        } catch {
            return status(.staged(.refused("\(error)")))
        }
    }
}
