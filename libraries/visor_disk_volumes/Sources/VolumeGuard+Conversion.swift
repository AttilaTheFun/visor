// The guard's part for a conversion: Stage's addVolume of `<Name>-new`
// (and its chown and chmod), Swap In's and unswap's renames, unmounts and
// mounts pass only as ConversionPlanner plans that step for a role the
// caller named, from the disks as they are just before they run; and a
// kept volume is deleted only by its UUID, its name asked for.

extension VolumeGuard {
    /// The diskutil verbs a conversion runs beside addVolume.
    static let conversionVerbs: Set<String> = ["rename", "unmount", "mount", "unmountDisk", "mountDisk"]

    /// Whether a command is of a conversion's kind: a rename, unmount or
    /// mount, an addVolume of a staged name (`Sessions-new`), or a chown or
    /// chmod of a staged mount point. None of them passes but as planned.
    static func isConversionCommand(_ command: DiskCommand) -> Bool {
        let arguments = command.arguments
        if command.program == DiskCommand.diskutil {
            if let verb = arguments.first, conversionVerbs.contains(verb) { return true }
            return arguments.count >= 5 && Array(arguments.prefix(2)) == ["apfs", "addVolume"]
                && VolumeRole.allCases.contains { $0.stagedName == arguments[4] }
        }
        if command.program == DiskCommand.chown || command.program == DiskCommand.chmod {
            return arguments.contains { argument in VolumeRole.allCases.contains { $0.stagedMountPoint == argument } }
        }
        return false
    }

    /// What a step plans for the role from the survey.
    static func planned(_ step: ConversionStep, role: VolumeRole, survey: DiskSurvey, user: String?) throws -> [DiskCommand] {
        switch step {
        case .stage:
            guard let user else { throw DiskVolumesError.notAllowed("a stage with no user to give \(role.stagedName) to") }
            return try ConversionPlanner.stageCommands(role, in: survey, user: user)
        case let .swap(marker, _):
            return try ConversionPlanner.swapCommands(role, in: survey, marker: marker)
        case .unswap:
            return try ConversionPlanner.unswapCommands(role, in: survey)
        }
    }

    /// The commands from `index` on must start with exactly the commands a
    /// role's step in `converting` plans (one not matched yet in this run):
    /// how many they are. Throws otherwise, saying what's planned.
    static func matchConversion(_ commands: [DiskCommand], at index: Int, survey: DiskSurvey, converting: [VolumeRole: ConversionStep],
                                used: inout Set<VolumeRole>, user: String?) throws -> Int {
        guard !converting.isEmpty else { throw DiskVolumesError.notAllowed(commands[index].description) }
        var reasons: [String] = []
        for role in VolumeRole.convertible where !used.contains(role) {
            guard let step = converting[role] else { continue }
            do {
                let plan = try planned(step, role: role, survey: survey, user: user)
                if !plan.isEmpty, index + plan.count <= commands.count, Array(commands[index..<(index + plan.count)]) == plan {
                    used.insert(role)
                    return plan.count
                }
                reasons.append("\(role.volumeName)'s is planned as \(plan.map(\.description).joined(separator: "; ")).")
            } catch {
                reasons.append("\(error)")
            }
        }
        throw DiskVolumesError.wrongTarget("\(commands[index].description) isn't a conversion step planned for the volumes as they are now. "
            + reasons.joined(separator: " ") + " Nothing was run.")
    }

    /// How many of the commands, from the first, are the root's check a
    /// swap or unswap starts with (0 or 1): with a role swapping or
    /// unswapping, the run must start with exactly the check planned for
    /// those roles, in exactly ConversionChecker's shape (Visor Disk
    /// Utility's bundle copied as root into a root-owned folder, the copy
    /// verified against its designated requirement, then run), so that
    /// nothing is renamed unless it passes and nothing the person could
    /// change runs as root. Swap and unswap aren't mixed in one run.
    static func checkFirst(_ commands: [DiskCommand], converting: [VolumeRole: ConversionStep], checker: ConversionChecker?) throws -> Int {
        var swaps: [(role: VolumeRole, digest: String)] = []
        var unswaps: [VolumeRole] = []
        for role in VolumeRole.convertible {
            switch converting[role] {
            case let .swap(_, digest)?: swaps.append((role, digest))
            case .unswap?: unswaps.append(role)
            case .stage?, nil: break
            }
        }
        guard !swaps.isEmpty || !unswaps.isEmpty else { return 0 }
        guard swaps.isEmpty || unswaps.isEmpty else { throw DiskVolumesError.notAllowed("a swap and an unswap in one run") }
        guard let checker else {
            throw DiskVolumesError.notAllowed("a swap or unswap without the root's check before it")
        }
        let planned = swaps.isEmpty ? ConversionPlanner.unswapCheck(checker: checker, roles: unswaps)
            : ConversionPlanner.swapCheck(checker: checker, markers: swaps)
        guard commands.first == planned else {
            throw DiskVolumesError.wrongTarget("A swap or unswap starts with its check (\(planned.description)), "
                + "so that nothing is renamed unless it passes. Nothing was run.")
        }
        return 1
    }

    /// Throws unless the kept volume's deletion was asked for, by its name,
    /// and it isn't mounted where Visor looks for its role's volume.
    static func checkKeptDelete(_ kept: KeptVolume, deletingKept: Set<String>) throws {
        guard deletingKept.contains(kept.name) else {
            throw DiskVolumesError.wrongTarget("\(kept.name) is deleted only when its deletion is asked for, its name typed. Nothing was deleted.")
        }
        guard kept.mountPoint != kept.role.mountPoint else {
            throw DiskVolumesError.wrongTarget("\(kept.name) is mounted at \(kept.role.mountPoint), where Visor looks for \(kept.role.volumeName): "
                + "it isn't deleted. Nothing was deleted.")
        }
    }
}
