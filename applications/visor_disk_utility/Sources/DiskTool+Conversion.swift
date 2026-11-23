// A conversion's steps, run (docs/volume-conversion.md): Stage and Swap In
// (and unswap, and a kept volume's deletion) through the administrator
// prompt, each checked by VolumeGuard against the disks as they are;
// copy-staged as the person, never root. Each refuses while Visor's server
// or its agents' hosts run, or anything but Spotlight has a file open on
// the volumes. Every call blocks: the app makes them off the main actor.

import Darwin
import DiskVolumes
import Foundation
import Security

extension DiskTool {
    /// The staged copy's marker, at `/Volumes/<Name>-new`; nil when there's
    /// none. Throws when there's one that can't be read.
    static func marker(for role: VolumeRole) throws -> ConversionMarker? {
        try ConversionMarker.read(atRoot: role.stagedMountPoint)
    }

    /// Where Sessions' and Sources' conversions stand.
    static func conversionStatuses(_ survey: DiskSurvey) -> [ConversionStatus] {
        VolumeRole.convertible.map { role in
            var marker: ConversionMarker?
            var problem: String?
            do { marker = try self.marker(for: role) } catch { problem = "\(error)" }
            return ConversionPlanner.status(role, in: survey, marker: marker, markerError: problem)
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
        // As the person, lsof sees the person's processes alone: the
        // source's listing, before and after the copy, catches a write by
        // any other, and Swap In checks again as root.
        try refuseOpenFiles(on: [role.mountPoint, role.stagedMountPoint])
        // A copy with no quota (its source had none) shares the container's
        // free space with the Mac: a tenth of it, at least 20 GB, stays free.
        let free = freeSpace(role.stagedMountPoint)
        let keepFree = pair.staged.quota > 0 ? 0 : free.map { ConversionPlanner.keptFree(containerFree: $0) } ?? 0
        say("copying \(role.mountPoint) (\(pair.source.device), \(pair.source.uuid)) onto \(role.stagedMountPoint) "
            + "(\(pair.staged.device), \(pair.staged.uuid))")
        return try ConversionCopy.copyAndVerify(role: role, from: role.mountPoint, to: role.stagedMountPoint, sourceUUID: pair.source.uuid,
                                                newUUID: pair.staged.uuid, owner: currentOwner(), inspector: DarwinFileInspector(),
                                                destinationFree: free, keepFree: keepFree, replace: replace,
                                                run: { _ = try run($0) }, say: say)
    }

    /// The bytes free on the volume at a path, as its filesystem says.
    static func freeSpace(_ path: String) -> Int64? {
        ((try? FileManager.default.attributesOfFileSystem(forPath: path))?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    /// The person running it: their user id and groups.
    static func currentOwner() -> FileOwner {
        let count = getgroups(0, nil)
        var groups = [gid_t](repeating: 0, count: Int(max(0, count)))
        let read = count > 0 ? getgroups(count, &groups) : 0
        return FileOwner(uid: getuid(), groups: Set(groups.prefix(Int(max(0, read)))).union([getgid()]))
    }

    /// Visor Disk Utility's own bundle and designated requirement: the
    /// root's check before a swap or unswap is a copy of it, made by root
    /// in a root-owned folder and verified against that requirement before
    /// it runs (ConversionChecker), never the bundle as it is, which the
    /// person (or any process of theirs) can write.
    static func verifiedChecker() throws -> ConversionChecker {
        let bundle = Bundle.main.bundleURL.path
        guard let executable = Bundle.main.executableURL?.lastPathComponent else {
            throw DiskVolumesError.blocked("Visor Disk Utility can't find its own executable for the root's check.")
        }
        let signature = try ownSignature()
        #if DEBUG
        let debugBuild = true
        #else
        let debugBuild = false
        #endif
        return try ConversionChecker(bundle: bundle, executable: executable, requirement: signature.requirement, team: signature.team,
                                     debugBuild: debugBuild)
    }

    /// The running app's designated requirement as text, and its team (nil
    /// when it's signed ad hoc).
    static func ownSignature() throws -> (requirement: String, team: String?) {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
            throw DiskVolumesError.blocked("Visor Disk Utility's own signature couldn't be read: the root's check can't be verified.")
        }
        var information: CFDictionary?
        _ = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        return (text as String, team)
    }

    /// For a test machine: the app's own bundle changed between the guard's
    /// look and the prompt (`VISOR_CONVERSION_TEST_TAMPER`: a file added to
    /// its Resources), as a process of the person's could, so the root's
    /// check can be shown to refuse a copy that fails its verification.
    static func testTamper() {
        guard ProcessInfo.processInfo.environment["VISOR_CONVERSION_TEST_TAMPER"] == "1",
              let resources = Bundle.main.resourceURL else { return }
        print("changing \(resources.path) before the prompt (VISOR_CONVERSION_TEST_TAMPER)")
        try? Data("tampered\n".utf8).write(to: resources.appendingPathComponent("tampered"))
    }

    /// Swap In: for each role, its marker checked (these two volumes, at
    /// most two hours old) and its volume unchanged since the copy, then
    /// the old volume renamed `<Name>-old-ci` and unmounted, the copy
    /// renamed `<Name>` and mounted again at `/Volumes/<Name>`, each by its
    /// disk, in one administrator prompt; then the marker removed.
    static func swap(_ roles: [VolumeRole], route: PrivilegeRoute) throws -> DiskSurvey {
        let disks = try survey()
        let checker = try verifiedChecker()
        var steps: [VolumeRole: ConversionStep] = [:]
        var digests: [(role: VolumeRole, digest: String)] = []
        var commands: [DiskCommand] = []
        for role in roles {
            let marker = try self.marker(for: role)
            commands += try ConversionPlanner.swapCommands(role, in: disks, marker: marker)
            if let marker {
                let digest = try ConversionMarker.fileDigest(atRoot: role.stagedMountPoint)
                steps[role] = .swap(marker, markerDigest: digest)
                digests.append((role, digest))
            }
        }
        // The person's checks first, for a refusal that says why before
        // the prompt; the root's again in the prompt, before the first rename.
        try refuseWhileVisorRuns()
        try refuseOpenFiles(on: roles.flatMap { [$0.mountPoint, $0.stagedMountPoint] })
        for role in roles {
            guard case let .swap(marker, _)? = steps[role] else { continue }
            try checkListings(role, marker: marker)
        }
        testPause()
        let after: DiskSurvey
        do {
            after = try change([ConversionPlanner.swapCheck(checker: checker, markers: digests)] + commands, route: route,
                               converting: steps, checker: checker)
        } catch let DiskVolumesError.failed(why) where why.contains(checkRefused) {
            throw DiskVolumesError.blocked(checkRefusal(why))
        } catch let DiskVolumesError.failed(why) {
            throw DiskVolumesError.failed("Swap In failed: \(why). It may have stopped part-way: `status` shows the volumes, and "
                + "`unswap \(roles.count == 1 ? roles[0].rawValue : "both")` puts the old one back.")
        }
        for role in roles {
            try? FileManager.default.removeItem(atPath: ConversionMarker.path(atRoot: role.mountPoint))
            // What it holds now, for unswap to tell whether it changed since.
            if let new = after.state(for: role).volume, let old = KeptVolume.found(in: after).first(where: { $0.role == role && $0.kind == .rollback }),
               let listing = try? VolumeManifest.make(of: role.mountPoint, .listing, inspector: DarwinFileInspector()) {
                try? ConversionNote(role: role, swapped: Date(), newUUID: new.uuid, oldUUID: old.volume.uuid, listingSHA256: listing.sha256)
                    .save(at: noteURL)
            }
        }
        return after
    }

    /// Swap In's notes, in Visor's data folder.
    static var noteURL: URL { ConversionNote.url(inDataDirectory: VisorFolders.locate().data) }

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
    static func unswap(_ roles: [VolumeRole], force: Bool, route: PrivilegeRoute, say: (String) -> Void = { _ in }) throws -> DiskSurvey {
        let checker = try verifiedChecker()
        let disks = try survey()
        let commands = try roles.flatMap { try ConversionPlanner.unswapCommands($0, in: disks) }
        let notes = ConversionNote.read(at: noteURL)
        for role in roles {
            // The converted volume where Visor looks, if it's there.
            let state = disks.state(for: role)
            guard state.isMountedInPlace, state.isCaseSensitive == true, let volume = state.volume else { continue }
            let listing = try VolumeManifest.make(of: role.mountPoint, .listing, inspector: DarwinFileInspector())
            if let warning = ConversionPlanner.unswapWarning(role, note: notes[role.rawValue], uuid: volume.uuid, listing: listing.sha256) {
                guard force else { throw DiskVolumesError.blocked(warning) }
                say("warning (--force): " + warning)
            }
        }
        try refuseWhileVisorRuns()
        try refuseOpenFiles(on: roles.flatMap { [$0.mountPoint, "/Volumes/" + $0.keptName] })
        do {
            return try change([ConversionPlanner.unswapCheck(checker: checker, roles: roles)] + commands, route: route,
                              converting: Dictionary(uniqueKeysWithValues: roles.map { ($0, .unswap) }), checker: checker)
        } catch let DiskVolumesError.failed(why) where why.contains(checkRefused) {
            throw DiskVolumesError.blocked(checkRefusal(why))
        }
    }

    /// The source's and the copy's listings (sizes, times) as the marker
    /// recorded them: else one changed since the copy was checked, and
    /// isn't swapped.
    static func checkListings(_ role: VolumeRole, marker: ConversionMarker) throws {
        let source = try VolumeManifest.make(of: role.mountPoint, .listing, inspector: DarwinFileInspector())
        guard source.sha256 == marker.sourceListingSHA256 else {
            throw DiskVolumesError.blocked("\(role.mountPoint) has changed since it was copied (a file added, removed, written or changed): "
                + "run copy-staged \(role.rawValue) --replace again, then Swap In. Nothing was swapped.")
        }
        let copy = try VolumeManifest.make(of: role.stagedMountPoint, .listing, inspector: DarwinFileInspector())
        guard copy.sha256 == marker.copyListingSHA256 else {
            throw DiskVolumesError.blocked("\(role.stagedMountPoint) has changed since it was checked: "
                + "run copy-staged \(role.rawValue) --replace again, then Swap In. Nothing was swapped.")
        }
    }

    /// What the root's check says when it refuses.
    static let checkRefused = "conversion-check refused"

    /// The root's check's refusal, from what the prompt's shell said (its
    /// error output, after the tool's own prefix).
    static func checkRefusal(_ said: String) -> String {
        said.range(of: checkRefused).map { String(said[$0.lowerBound...]) } ?? said
    }

    /// `conversion-check swap <role> <marker sha256>…` or `conversion-check
    /// unswap <role>…`: run as root in the administrator prompt's shell,
    /// first, so the renames after it run only if it passes. A swap's
    /// marker must still be the file the person's checks read (its
    /// sha256), name the volumes there now and be at most two hours old by
    /// this Mac's clock, and the source's and the copy's listings must
    /// still be the marker's; for both, Visor stopped and nothing open on the volumes,
    /// as root's lsof sees every process. Throws, saying nothing was
    /// changed, otherwise.
    static func conversionCheck(_ arguments: [String]) throws {
        do {
            guard arguments.count >= 3, ["swap", "unswap"].contains(arguments[1]) else {
                throw DiskVolumesError.blocked("conversion-check swap <role> <marker sha256>… | unswap <role>…")
            }
            let disks = try survey()
            var mounts: [String] = []
            if arguments[1] == "swap" {
                let pairs = Array(arguments.dropFirst(2))
                guard pairs.count % 2 == 0 else { throw DiskVolumesError.blocked("conversion-check swap <role> <marker sha256>…") }
                for index in stride(from: 0, to: pairs.count, by: 2) {
                    guard let role = VolumeRole.conversionRoles(pairs[index]), role.count == 1 else {
                        throw DiskVolumesError.blocked("\(pairs[index]) isn't sessions or sources")
                    }
                    let pair = try ConversionPlanner.copyPair(role[0], in: disks)
                    guard try ConversionMarker.fileDigest(atRoot: role[0].stagedMountPoint) == pairs[index + 1],
                          let marker = try marker(for: role[0]) else {
                        throw DiskVolumesError.blocked("\(role[0].stagedName)'s marker isn't the one checked before the prompt")
                    }
                    try marker.check(role: role[0], sourceUUID: pair.source.uuid, newUUID: pair.staged.uuid)
                    try checkListings(role[0], marker: marker)
                    mounts += [role[0].mountPoint, role[0].stagedMountPoint]
                }
            } else {
                for name in arguments.dropFirst(2) {
                    guard let role = VolumeRole.conversionRoles(name), role.count == 1 else { throw DiskVolumesError.blocked("\(name) isn't sessions or sources") }
                    mounts += [role[0].mountPoint, "/Volumes/" + role[0].keptName]
                }
            }
            try refuseWhileVisorRuns()
            try refuseOpenFiles(on: mounts)
            print("conversion-check: as it was checked, and nothing open")
        } catch {
            let said = "\(error)"
            throw DiskVolumesError.failed("\(checkRefused) (as root, just before the first rename): \(said)"
                + (said.contains("Nothing was") ? "" : " Nothing was changed."))
        }
    }

    /// For a test machine: a pause, in seconds, between the person's checks
    /// and the prompt (`VISOR_CONVERSION_TEST_PAUSE`), so a write in it can
    /// be shown to be caught by the root's check.
    private static func testPause() {
        guard let text = ProcessInfo.processInfo.environment["VISOR_CONVERSION_TEST_PAUSE"], let seconds = Double(text), seconds > 0 else { return }
        print("pausing \(seconds) s before the prompt (VISOR_CONVERSION_TEST_PAUSE)")
        fflush(stdout)
        Thread.sleep(forTimeInterval: min(seconds, 600))
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
    /// volumes mounted at these paths (`lsof -F pcn <mount point>`), the
    /// system's own folders aside. As the person, lsof sees their
    /// processes alone; as root (the check in the prompt), every process.
    static func refuseOpenFiles(on mountPoints: [String]) throws {
        for mountPoint in mountPoints where DiskVolumes.isMountPoint(mountPoint) {
            let (_, output, _) = try outcome(["/usr/sbin/lsof", "-F", "pcn", mountPoint])
            let holders = ConversionPreflight.holders(lsof: String(decoding: output, as: UTF8.self), mountPoint: mountPoint)
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
