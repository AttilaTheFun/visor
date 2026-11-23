// A conversion's steps, run (docs/volume-conversion.md): Stage and Swap In
// (and unswap, and a kept volume's deletion) through the administrator
// prompt, each checked by VolumeGuard against the disks as they are;
// copy-staged as the person, never root. Each refuses while Visor's server
// or its agents' hosts run, or anything but Spotlight has a file open on
// the volumes. Every call blocks: the app makes them off the main actor.

import Darwin
import DiskVolumes
import Foundation

extension DiskTool {
    /// The staged copy's marker, at `/Volumes/<Name>-new`; nil when there's
    /// none. Throws when there's one that can't be read.
    static func marker(for role: VolumeRole) throws -> ConversionMarker? {
        try ConversionMarker.read(atRoot: role.stagedMountPoint)
    }

    /// Where Sessions' and Sources' conversions stand.
    static func conversionStatuses(_ survey: DiskSurvey, now: Date = Date()) -> [ConversionStatus] {
        VolumeRole.convertible.map { role in
            var marker: ConversionMarker?
            var problem: String?
            do { marker = try self.marker(for: role) } catch { problem = "\(error)" }
            return ConversionPlanner.status(role, in: survey, marker: marker, markerError: problem, now: now)
        }
    }

    /// Stage: `<Name>-new` made for each role, case-sensitive, with the
    /// role volume's quota and reserve, and given to the person; one
    /// administrator prompt.
    static func stage(_ roles: [VolumeRole], route: PrivilegeRoute) throws -> DiskSurvey {
        let disks = try survey()
        let commands = try roles.flatMap { try ConversionPlanner.stageCommands($0, in: disks, user: user) }
        return try change(commands, route: route, converting: Dictionary(uniqueKeysWithValues: roles.map { ($0, .stage) }))
    }

    /// copy-staged: the role's volume copied onto its staged copy and
    /// checked, and the marker written; as the person, never root.
    @discardableResult
    static func copyStaged(_ role: VolumeRole, replace: Bool, say: (String) -> Void) throws -> ConversionMarker {
        guard getuid() != 0 else {
            throw DiskVolumesError.blocked("copy-staged runs as the volumes' owner, never as root (no sudo): the copy's files are theirs.")
        }
        let disks = try survey()
        let pair = try ConversionPlanner.copyPair(role, in: disks)
        guard FileManager.default.isWritableFile(atPath: role.stagedMountPoint) else {
            throw DiskVolumesError.blocked("\(role.stagedMountPoint) isn't writable by \(user) (owned by \(owner(of: role.stagedMountPoint) ?? "?")): "
                + "it's given to the person who staged it.")
        }
        try refuseWhileVisorRuns()
        try refuseOpenFiles(on: [role.mountPoint, role.stagedMountPoint])
        say("copying \(role.mountPoint) (\(pair.source.device), \(pair.source.uuid)) onto \(role.stagedMountPoint) "
            + "(\(pair.staged.device), \(pair.staged.uuid))")
        return try ConversionCopy.copyAndVerify(role: role, from: role.mountPoint, to: role.stagedMountPoint, sourceUUID: pair.source.uuid,
                                                newUUID: pair.staged.uuid, replace: replace, run: { _ = try run($0) }, say: say)
    }

    /// Swap In: for each role, its marker checked (these two volumes, at
    /// most two hours old) and its volume unchanged since the copy, then
    /// the old volume renamed `<Name>-old-ci` and unmounted, the copy
    /// renamed `<Name>` and mounted again at `/Volumes/<Name>`, each by its
    /// disk, in one administrator prompt; then the marker removed.
    static func swap(_ roles: [VolumeRole], route: PrivilegeRoute, now: Date = Date()) throws -> DiskSurvey {
        let disks = try survey()
        var steps: [VolumeRole: ConversionStep] = [:]
        var commands: [DiskCommand] = []
        for role in roles {
            let marker = try self.marker(for: role)
            commands += try ConversionPlanner.swapCommands(role, in: disks, marker: marker, now: now)
            if let marker { steps[role] = .swap(marker, now: now) }
        }
        try refuseWhileVisorRuns()
        try refuseOpenFiles(on: roles.flatMap { [$0.mountPoint, $0.stagedMountPoint] })
        for role in roles {
            guard case let .swap(marker, _)? = steps[role] else { continue }
            let listing = try VolumeManifest.make(of: role.mountPoint, .listing)
            guard listing.sha256 == marker.sourceListingSHA256 else {
                throw DiskVolumesError.blocked("\(role.mountPoint) has changed since it was copied (a file added, removed or written): "
                    + "run copy-staged \(role.rawValue) --replace again, then Swap In. Nothing was swapped.")
            }
        }
        let after: DiskSurvey
        do {
            after = try change(commands, route: route, converting: steps)
        } catch let DiskVolumesError.failed(why) {
            throw DiskVolumesError.failed("Swap In failed: \(why). It may have stopped part-way: `status` shows the volumes, and "
                + "`unswap \(roles.count == 1 ? roles[0].rawValue : "both")` puts the old one back.")
        }
        for role in roles {
            try? FileManager.default.removeItem(atPath: ConversionMarker.path(atRoot: role.mountPoint))
        }
        return after
    }

    /// What Swap In left, a line a role: its personality, mount point and
    /// owner, and the volume kept for rollback.
    static func swapResult(_ roles: [VolumeRole], in survey: DiskSurvey) -> [String] {
        roles.map { role in
            let state = survey.state(for: role)
            guard let info = state.info, state.isMountedInPlace else {
                return "\(role.volumeName) isn't mounted at \(role.mountPoint) after the swap: see Disk Utility, or unswap \(role.rawValue)."
            }
            let marker = FileManager.default.fileExists(atPath: ConversionMarker.path(atRoot: role.mountPoint))
                ? " Its marker is still there: remove \(ConversionMarker.path(atRoot: role.mountPoint))." : ""
            let kept = KeptVolume.found(in: survey).first { $0.role == role && $0.kind == .rollback }
            return "\(role.volumeName): \(info.filesystemName), mounted at \(info.mountPoint ?? "?"), owned by \(owner(of: role.mountPoint) ?? "?")."
                + (kept.map { " \($0.summary)." } ?? "") + marker
        }
    }

    /// unswap: the old volume put back at `/Volumes/<Name>`, the converted
    /// one renamed `<Name>-cs-failed` and unmounted; one administrator
    /// prompt.
    static func unswap(_ roles: [VolumeRole], route: PrivilegeRoute) throws -> DiskSurvey {
        let disks = try survey()
        let commands = try roles.flatMap { try ConversionPlanner.unswapCommands($0, in: disks) }
        try refuseWhileVisorRuns()
        try refuseOpenFiles(on: roles.flatMap { [$0.mountPoint, "/Volumes/" + $0.keptName] })
        return try change(commands, route: route, converting: Dictionary(uniqueKeysWithValues: roles.map { ($0, .unswap) }))
    }

    /// A kept volume deleted, by its UUID, its confirmation typed ("delete
    /// Sessions-old-ci"); the administrator prompt.
    static func deleteKept(_ name: String, typed: String, route: PrivilegeRoute) throws -> DiskSurvey {
        let disks = try survey()
        guard let kept = KeptVolume.named(name, in: disks) else {
            throw DiskVolumesError.blocked("There's no one volume named \(name) kept by a conversion here.")
        }
        guard kept.matches(typed) else { throw DiskVolumesError.blocked("Type \"\(kept.confirmation)\" to delete it.") }
        return try change([try kept.deleteCommand()], route: route, deletingKept: [kept.name])
    }

    /// Throws while Visor's server, its app or its agents' hosts run, or
    /// something answers on its port.
    static func refuseWhileVisorRuns() throws {
        let listed = String(decoding: try run(["/bin/ps", "-axo", "pid=,comm="]), as: UTF8.self)
        let processes = ConversionPreflight.visorProcesses(ps: listed)
        if let why = ConversionPreflight.serverRefusal(processes: processes, portAnswers: answers(port: ConversionPreflight.serverPort)) {
            throw DiskVolumesError.blocked(why)
        }
    }

    /// Throws while anything but Spotlight has a file open on one of the
    /// volumes mounted at these paths (`lsof <mount point>`, as the person).
    static func refuseOpenFiles(on mountPoints: [String]) throws {
        for mountPoint in mountPoints where DiskVolumes.isMountPoint(mountPoint) {
            let (_, output, _) = try outcome(["/usr/sbin/lsof", mountPoint])
            let holders = ConversionPreflight.holders(lsof: String(decoding: output, as: UTF8.self))
            if let why = ConversionPreflight.openFilesRefusal(mountPoint: mountPoint, holders: holders) {
                throw DiskVolumesError.blocked(why)
            }
        }
    }

    /// Whether something accepts a connection on this Mac's loopback at
    /// the port.
    static func answers(port: Int) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }
}
