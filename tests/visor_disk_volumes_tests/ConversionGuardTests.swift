// The guard on a conversion's commands: an addVolume of `<Name>-new`, a
// rename, an unmount or a mount runs only as ConversionPlanner plans the
// step the caller named, for these exact names and disks; a kept volume is
// deleted only by its UUID, its name asked for.

import DiskVolumes
import Foundation
import Testing

@Suite struct ConversionGuardTests {
    private let now = ConversionDisks.now
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

    @Test func swapPassesAsPlannedWithItsMarkerAlone() throws {
        let staged = ConversionDisks.staged()
        let marker = ConversionDisks.marker(.sessions)
        let swap = try ConversionPlanner.swapCommands(.sessions, in: staged, marker: marker, now: now)
        try VolumeGuard.check(swap, against: staged, converting: [.sessions: .swap(marker, now: now)])
        let both = swap + (try ConversionPlanner.swapCommands(.sources, in: staged, marker: ConversionDisks.marker(.sources), now: now))
        try VolumeGuard.check(both, against: staged, converting: [.sessions: .swap(marker, now: now),
                                                              .sources: .swap(ConversionDisks.marker(.sources), now: now)])
        // A stale marker by the time the guard looks, or another's.
        let later = now.addingTimeInterval(3 * 60 * 60)
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check(swap, against: staged, converting: [.sessions: .swap(marker, now: later)]) }
        #expect(throws: DiskVolumesError.self) {
            try VolumeGuard.check(swap, against: staged, converting: [.sessions: .swap(ConversionDisks.marker(.sources), now: now)])
        }
        // Not asked, or asked for Stage.
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check(swap, against: staged) }
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check(swap, against: staged, user: "logan", converting: [.sessions: .stage]) }
        // Part of it, or in another order.
        let swapping: [VolumeRole: ConversionStep] = [.sessions: .swap(marker, now: now)]
        for attempt in [Array(swap.dropFirst(2)), Array(swap.prefix(3)), [swap[2], swap[3], swap[4], swap[0], swap[1]], swap + [swap[4]]] {
            #expect(throws: DiskVolumesError.self, "\(attempt)") { try VolumeGuard.check(attempt, against: staged, converting: swapping) }
        }
    }

    @Test func renameUnmountAndMountRunForTheseNamesAndDisksAlone() throws {
        let staged = ConversionDisks.staged()
        let marker = ConversionDisks.marker(.sessions)
        let swapping: [VolumeRole: ConversionStep] = [.sessions: .swap(marker, now: now)]
        var planned = try ConversionPlanner.swapCommands(.sessions, in: staged, marker: marker, now: now)
        for (index, replacement) in [(0, command("rename", "disk3s7", "Sessions-old")), (0, command("rename", "disk3s7", "Visor")),
                                     (0, command("rename", "disk3s9", "Sessions-old-ci")), (0, command("rename", "/Volumes/Sessions", "Sessions-old-ci")),
                                     (1, command("unmount", "force", "disk3s7")), (1, command("unmount", "/Volumes/Sessions")),
                                     (1, command("unmountDisk", "disk3")), (2, command("rename", "disk3s10", "Sources")),
                                     (2, command("rename", "Sessions-new", "Sessions")), (4, command("mount", "disk3s7")),
                                     (4, command("mount", "-mountPoint", "/", "disk3s10"))] {
            var attempt = planned
            attempt[index] = replacement
            #expect(throws: DiskVolumesError.self, "\(replacement)") { try VolumeGuard.check(attempt, against: staged, converting: swapping) }
        }
        // None of them alone, whatever the caller says it's doing.
        planned = [command("mount", "disk3s10")]
        for converting: [VolumeRole: ConversionStep] in [[:], swapping, [.sessions: .unswap], [.sessions: .stage]] {
            #expect(throws: DiskVolumesError.self) { try VolumeGuard.check(planned, against: staged, user: "logan", converting: converting) }
        }
        #expect(throws: DiskVolumesError.notAllowed("diskutil rename disk3s7 Sessions-old-ci")) {
            try VolumeGuard.check([command("rename", "disk3s7", "Sessions-old-ci")], against: staged)
        }
    }

    @Test func unswapPassesAsPlanned() throws {
        let swapped = ConversionDisks.swapped()
        let unswap = try ConversionPlanner.unswapCommands(.sessions, in: swapped)
        try VolumeGuard.check(unswap, against: swapped, converting: [.sessions: .unswap])
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check(unswap, against: swapped) }
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check(unswap, against: swapped, converting: [.sources: .unswap]) }
        // Once undone, the same commands are refused.
        var undone = swapped
        ConversionDisks.rename(&undone, "disk3s10", to: "Sessions-cs-failed", mountedAt: nil)
        ConversionDisks.rename(&undone, "disk3s7", to: "Sessions", mountedAt: "/Volumes/Sessions")
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check(unswap, against: undone, converting: [.sessions: .unswap]) }
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
