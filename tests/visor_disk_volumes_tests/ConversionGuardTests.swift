// The guard on a conversion's commands: an addVolume of `<Name>-new`, a
// rename, an unmount or a mount runs only as ConversionPlanner plans the
// step the caller named, for these exact names and disks; a kept volume is
// deleted only by its UUID, its name asked for.

import DiskVolumes
import Foundation
import Testing

@Suite struct ConversionGuardTests {
    /// The guard checks a marker's age by this Mac's clock as it looks,
    /// never a time it's given: the markers here are dated by it.
    private let now = Date()
    private func command(_ arguments: String...) -> DiskCommand { DiskCommand(arguments: arguments) }

    @Test func stagePassesAsPlannedForTheRolesNamed() throws {
        let mini = ConversionDisks.mini()
        let sessions = try ConversionPlanner.stageCommands(.sessions, in: mini, user: "logan")
        let sources = try ConversionPlanner.stageCommands(.sources, in: mini, user: "logan")
        try VolumeGuard.check(sessions + sources, against: mini, user: "logan", converting: [.sessions: .stage, .sources: .stage])
        try VolumeGuard.check(sessions, against: mini, user: "logan", converting: [.sessions: .stage])
        // Not named, or named for another step or role: refused.
        for converting: [VolumeRole: ConversionStep] in [[:], [.sources: .stage], [.sessions: .unswap]] {
            #expect(throws: DiskVolumesError.self, "\(converting)") {
                try VolumeGuard.check(sessions, against: mini, user: "logan", converting: converting)
            }
        }
        // Planned again from the disks as they are: once staged, refused.
        #expect(throws: DiskVolumesError.self) {
            try VolumeGuard.check(sessions, against: ConversionDisks.staged([.sessions]), user: "logan", converting: [.sessions: .stage])
        }
        // Another user's, or none.
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check(sessions, against: mini, user: "other", converting: [.sessions: .stage]) }
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check(sessions, against: mini, converting: [.sessions: .stage]) }
    }

    @Test func aStageOtherThanPlannedIsRefused() throws {
        let mini = ConversionDisks.mini()
        let stage: [VolumeRole: ConversionStep] = [.sessions: .stage]
        let chown = DiskCommand(program: DiskCommand.chown, arguments: ["logan:staff", "/Volumes/Sessions-new"])
        let chmod = DiskCommand(program: DiskCommand.chmod, arguments: ["775", "/Volumes/Sessions-new"])
        let attempts: [[DiskCommand]] = [
            // Another quota, none, a reserve, another format, another container, another name.
            [command("apfs", "addVolume", "disk3", "Case-sensitive APFS", "Sessions-new", "-quota", "50000000000b"), chown, chmod],
            [command("apfs", "addVolume", "disk3", "Case-sensitive APFS", "Sessions-new"), chown, chmod],
            [command("apfs", "addVolume", "disk3", "Case-sensitive APFS", "Sessions-new", "-quota", "40000000000b", "-reserve", "1b"), chown, chmod],
            [command("apfs", "addVolume", "disk3", "APFS", "Sessions-new", "-quota", "40000000000b"), chown, chmod],
            [command("apfs", "addVolume", "disk5", "Case-sensitive APFS", "Sessions-new", "-quota", "40000000000b"), chown, chmod],
            [command("apfs", "addVolume", "disk3", "Case-sensitive APFS", "Visor-new"), chown, chmod],
            // Its chown and chmod otherwise, or alone.
            [command("apfs", "addVolume", "disk3", "Case-sensitive APFS", "Sessions-new", "-quota", "40000000000b"),
             DiskCommand(program: DiskCommand.chown, arguments: ["-R", "logan:staff", "/Volumes/Sessions-new"]), chmod],
            [command("apfs", "addVolume", "disk3", "Case-sensitive APFS", "Sessions-new", "-quota", "40000000000b"), chown,
             DiskCommand(program: DiskCommand.chmod, arguments: ["777", "/Volumes/Sessions-new"])],
            [chown, chmod],
        ]
        for attempt in attempts {
            #expect(throws: DiskVolumesError.self, "\(attempt)") { try VolumeGuard.check(attempt, against: mini, user: "logan", converting: stage) }
        }
    }

    /// Visor Disk Utility's own executable, which a swap's and an
    /// unswap's prompt start with, as root.
    private let checker = "/Applications/Visor Disk Utility.app/Contents/MacOS/Visor Disk Utility"
    private let digest = String(repeating: "9f", count: 32)

    private func swapping(_ roles: [VolumeRole], minutesOld: Double = 10) -> [VolumeRole: ConversionStep] {
        Dictionary(uniqueKeysWithValues: roles.map {
            ($0, ConversionStep.swap(ConversionDisks.marker($0, minutesOld: minutesOld, now: now), markerDigest: digest))
        })
    }

    private func check(_ roles: [VolumeRole]) -> DiskCommand {
        ConversionPlanner.swapCheck(checker: checker, markers: roles.map { ($0, digest) })
    }

    @Test func swapPassesAsPlannedAfterTheRootsCheck() throws {
        let staged = ConversionDisks.staged()
        let marker = ConversionDisks.marker(.sessions, now: now)
        let swap = try ConversionPlanner.swapCommands(.sessions, in: staged, marker: marker, now: now)
        #expect(check([.sessions]).argv == [checker, "conversion-check", "swap", "sessions", digest])
        try VolumeGuard.check([check([.sessions])] + swap, against: staged, converting: swapping([.sessions]), checker: checker)
        let both = swap + (try ConversionPlanner.swapCommands(.sources, in: staged, marker: ConversionDisks.marker(.sources, now: now), now: now))
        try VolumeGuard.check([check([.sessions, .sources])] + both, against: staged, converting: swapping([.sessions, .sources]), checker: checker)
        // Without the check first, or with another's, or no checker: refused.
        for attempt in [swap, [check([.sources])] + swap, swap + [check([.sessions])], [check([.sessions, .sources])] + swap] {
            #expect(throws: DiskVolumesError.self, "\(attempt)") {
                try VolumeGuard.check(attempt, against: staged, converting: swapping([.sessions]), checker: checker)
            }
        }
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check([check([.sessions])] + swap, against: staged, converting: swapping([.sessions])) }
        let elsewhere = DiskCommand(program: "/tmp/other", arguments: check([.sessions]).arguments)
        #expect(throws: DiskVolumesError.self) {
            try VolumeGuard.check([elsewhere] + swap, against: staged, converting: swapping([.sessions]), checker: checker)
        }
        // The check alone, unasked: never run.
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check([check([.sessions])], against: staged, checker: checker) }
        // A stale marker by the time the guard looks, or another's.
        #expect(throws: DiskVolumesError.self) {
            try VolumeGuard.check([check([.sessions])] + swap, against: staged, converting: swapping([.sessions], minutesOld: 121), checker: checker)
        }
        #expect(throws: DiskVolumesError.self) {
            try VolumeGuard.check([check([.sessions])] + swap, against: staged,
                                  converting: [.sessions: .swap(ConversionDisks.marker(.sources, now: now), markerDigest: digest)], checker: checker)
        }
        // Asked for Stage.
        #expect(throws: DiskVolumesError.self) {
            try VolumeGuard.check([check([.sessions])] + swap, against: staged, user: "logan", converting: [.sessions: .stage], checker: checker)
        }
        // Part of it, or in another order.
        for attempt in [Array(swap.dropFirst(2)), Array(swap.prefix(3)), [swap[2], swap[3], swap[4], swap[0], swap[1]], swap + [swap[4]]] {
            #expect(throws: DiskVolumesError.self, "\(attempt)") {
                try VolumeGuard.check([check([.sessions])] + attempt, against: staged, converting: swapping([.sessions]), checker: checker)
            }
        }
    }

    @Test func renameUnmountAndMountRunForTheseNamesAndDisksAlone() throws {
        let staged = ConversionDisks.staged()
        let marker = ConversionDisks.marker(.sessions, now: now)
        var planned = try ConversionPlanner.swapCommands(.sessions, in: staged, marker: marker, now: now)
        for (index, replacement) in [(0, command("rename", "disk3s7", "Sessions-old")), (0, command("rename", "disk3s7", "Visor")),
                                     (0, command("rename", "disk3s9", "Sessions-old-ci")), (0, command("rename", "/Volumes/Sessions", "Sessions-old-ci")),
                                     (1, command("unmount", "force", "disk3s7")), (1, command("unmount", "/Volumes/Sessions")),
                                     (1, command("unmountDisk", "disk3")), (2, command("rename", "disk3s10", "Sources")),
                                     (2, command("rename", "Sessions-new", "Sessions")), (4, command("mount", "disk3s7")),
                                     (4, command("mount", "-mountPoint", "/", "disk3s10"))] {
            var attempt = planned
            attempt[index] = replacement
            #expect(throws: DiskVolumesError.self, "\(replacement)") {
                try VolumeGuard.check([check([.sessions])] + attempt, against: staged, converting: swapping([.sessions]), checker: checker)
            }
        }
        // None of them alone, whatever the caller says it's doing.
        planned = [command("mount", "disk3s10")]
        for converting: [VolumeRole: ConversionStep] in [[:], swapping([.sessions]), [.sessions: .unswap], [.sessions: .stage]] {
            #expect(throws: DiskVolumesError.self) {
                try VolumeGuard.check(planned, against: staged, user: "logan", converting: converting, checker: checker)
            }
        }
        #expect(throws: DiskVolumesError.notAllowed("diskutil rename disk3s7 Sessions-old-ci")) {
            try VolumeGuard.check([command("rename", "disk3s7", "Sessions-old-ci")], against: staged)
        }
    }

    @Test func unswapPassesAsPlannedAfterTheRootsCheck() throws {
        let swapped = ConversionDisks.swapped()
        let unswap = try ConversionPlanner.unswapCommands(.sessions, in: swapped)
        let first = ConversionPlanner.unswapCheck(checker: checker, roles: [.sessions])
        #expect(first.argv == [checker, "conversion-check", "unswap", "sessions"])
        try VolumeGuard.check([first] + unswap, against: swapped, converting: [.sessions: .unswap], checker: checker)
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check(unswap, against: swapped, converting: [.sessions: .unswap], checker: checker) }
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check([first] + unswap, against: swapped, checker: checker) }
        #expect(throws: DiskVolumesError.self) {
            try VolumeGuard.check([first] + unswap, against: swapped, converting: [.sources: .unswap], checker: checker)
        }
        // A swap and an unswap aren't mixed.
        #expect(throws: DiskVolumesError.self) {
            try VolumeGuard.check([first] + unswap, against: swapped,
                                  converting: [.sessions: .unswap, .sources: .swap(ConversionDisks.marker(.sources, now: now), markerDigest: digest)],
                                  checker: checker)
        }
        // Once undone, the same commands are refused.
        var undone = swapped
        ConversionDisks.rename(&undone, "disk3s10", to: "Sessions-cs-failed", mountedAt: nil)
        ConversionDisks.rename(&undone, "disk3s7", to: "Sessions", mountedAt: "/Volumes/Sessions")
        #expect(throws: DiskVolumesError.self) {
            try VolumeGuard.check([first] + unswap, against: undone, converting: [.sessions: .unswap], checker: checker)
        }
    }

    @Test func aKeptVolumeIsDeletedByItsUUIDItsNameAskedFor() throws {
        let swapped = ConversionDisks.swapped()
        let kept = try #require(KeptVolume.named("Sessions-old-ci", in: swapped))
        let delete = try kept.deleteCommand()
        #expect(delete.description == "diskutil apfs deleteVolume \(ConversionDisks.sessionsUUID)")
        try VolumeGuard.check([delete], against: swapped, deletingKept: ["Sessions-old-ci"])
        for deletingKept: Set<String> in [[], ["Sources-old-ci"], ["Sessions"]] {
            #expect(throws: DiskVolumesError.self, "\(deletingKept)") {
                try VolumeGuard.check([delete], against: swapped, deleting: [.sessions], deletingKept: deletingKept)
            }
        }
        // By its disk, never.
        #expect(throws: DiskVolumesError.self) {
            try VolumeGuard.check([command("apfs", "deleteVolume", "disk3s7")], against: swapped, deletingKept: ["Sessions-old-ci"])
        }
        // The Sessions in place is never a kept one, whatever's asked.
        let sessions = command("apfs", "deleteVolume", ConversionDisks.sessionsNewUUID)
        #expect(throws: DiskVolumesError.sessionsNeverErased(sessions.description)) {
            try VolumeGuard.check([sessions], against: swapped, deletingKept: ["Sessions-old-ci", "Sessions"])
        }
        // The confirmation, typed.
        #expect(kept.confirmation == "delete Sessions-old-ci")
        #expect(kept.matches(" delete Sessions-old-ci\n"))
        #expect(!kept.matches("delete sessions-old-ci"))
        #expect(KeptVolume.found(in: swapped).map(\.name) == ["Sessions-old-ci", "Sources-old-ci"])
    }
}
