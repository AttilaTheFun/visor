// Sessions is never erased or deleted, however the command is made, unless
// its deletion is asked for (Uninstall…); and none of Visor's volumes is
// deleted unless asked for.

import DiskVolumes
import Foundation
import Testing

@Suite struct GuardTests {
    private func command(_ arguments: String...) -> DiskCommand { DiskCommand(arguments: arguments) }

    @Test func sessionsIsDeletedOnlyWhenAskedFor() throws {
        let survey = try Disks.both()
        let delete = try survey.state(for: .sessions).deleteCommands()
        #expect(delete.map(\.description) == ["diskutil apfs deleteVolume 86410F75-D43C-49E6-95C6-B20A5CBB16F2"])
        for deleting: Set<VolumeRole> in [[], [.visor], [.sources, .visor]] {
            #expect(throws: DiskVolumesError.sessionsNeverErased(delete[0].description)) {
                try VolumeGuard.check(delete, against: survey, deleting: deleting)
            }
        }
        try VolumeGuard.check(delete, against: survey, deleting: [.sessions])
        // Asked for, an erase of it is still refused: only a delete runs.
        let erase = command("apfs", "eraseVolume", "86410F75-D43C-49E6-95C6-B20A5CBB16F2")
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check([erase], against: survey, deleting: [.sessions]) }
    }

    @Test func aHandMadeDeleteOrEraseOfSessionsIsRefused() throws {
        for survey in [try Disks.both(), try Disks.caseInsensitiveSessions()] {
            let device = try #require(survey.state(for: .sessions).volume?.device)
            let uuid = try #require(survey.state(for: .sessions).volume?.uuid)
            for attempt in [command("apfs", "deleteVolume", device), command("apfs", "deleteVolume", uuid),
                            command("apfs", "deleteVolume", uuid.lowercased()), command("apfs", "eraseVolume", device, "-name", "Visor"),
                            command("apfs", "eraseVolume", "/Volumes/Sessions", "-name", "x"), command("eraseVolume", "APFS", "x", device),
                            command("apfs", "deleteVolume", "Sessions"), command("reformat", "/Volumes/Sessions/")] {
                #expect(throws: DiskVolumesError.sessionsNeverErased(attempt.description), "\(attempt)") {
                    try VolumeGuard.check([attempt], against: survey)
                }
            }
        }
    }

    @Test func sessionsUnderAnotherNameIsStillRefused() throws {
        var survey = try Disks.caseInsensitiveSessions()
        survey.containers[0].volumes[2].name = "Work"
        survey.infos[0].volumeName = "Work"
        for target in ["disk3s7", "68AEACEE-B314-4A78-ADAF-789D4F4FDA99"] {
            let attempt = command("apfs", "deleteVolume", target)
            #expect(throws: DiskVolumesError.sessionsNeverErased(attempt.description)) { try VolumeGuard.check([attempt], against: survey) }
        }
    }

    @Test func deletingVisorPassesOnlyWhenAskedFor() throws {
        let survey = try Disks.both()
        let commands = try survey.state(for: .visor).deleteCommands()
        #expect(commands.map(\.description) == ["diskutil apfs deleteVolume 4EF85269-E4B1-4058-A1FA-E9240A971CC9"])
        let error = #expect(throws: DiskVolumesError.self) { try VolumeGuard.check(commands, against: survey) }
        #expect(error?.description.contains("deleted only when its deletion is asked for") == true)
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check(commands, against: survey, deleting: [.sources]) }
        try VolumeGuard.check(commands, against: survey, deleting: [.visor])
    }

    @Test func onlyAddingAndDeletingVisorsOwnRun() throws {
        let survey = try Disks.both()
        let data = command("apfs", "deleteVolume", "disk3s5")
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check([data], against: survey, deleting: Set(VolumeRole.allCases)) }
        let unknown = command("apfs", "deleteVolume", "disk9s9")
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check([unknown], against: survey) }
        for other in [command("eraseDisk", "APFS", "x", "disk0"), command("apfs", "list"), command("unmount", "/Volumes/Visor"),
                      command("apfs", "addVolume", "disk3", "APFS", "Other")] {
            #expect(throws: DiskVolumesError.notAllowed(other.description)) { try VolumeGuard.check([other], against: survey) }
        }
        let extra = command("apfs", "addVolume", "disk3", "Case-sensitive APFS", "Visor", "-mountpoint", "/")
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check([extra], against: try Disks.fresh()) }
    }

    @Test func anExistingVolumeIsNeverMadeTwice() throws {
        let survey = try Disks.caseInsensitiveSessions()
        let again = try DiskCommand.addVolume(.sessions, container: "disk3", reserve: 0, quota: 0)
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check([again], against: survey) }
        try VolumeGuard.check([try DiskCommand.addVolume(.visor, container: "disk3", reserve: 0, quota: 0)], against: survey)
        let elsewhere = try DiskCommand.addVolume(.visor, container: "disk9", reserve: 0, quota: 0)
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check([elsewhere], against: survey) }
    }

    // NCH's review of #465: a volume is deleted only when it's Visor's,
    // only by its UUID, and nothing joins a second command in.

    private static let visorUUID = "4EF85269-E4B1-4058-A1FA-E9240A971CC9"

    /// Both volumes, Visor mounted at `place` instead (nil: not mounted).
    private func visor(mountedAt place: String?) throws -> DiskSurvey {
        var survey = try Disks.both()
        let index = try #require(survey.infos.firstIndex { $0.volumeName == "Visor" })
        survey.infos[index].mountPoint = place
        return survey
    }

    private func recording(_ uuid: String) -> VolumesStatus {
        VolumesStatus(updated: Date(), volumes: [], ownVolumes: ["visor": uuid])
    }

    @Test func aVisorThatIsntVisorsIsRefused() throws {
        for place in ["/Volumes/Visor 1", "/Users/someone/Visor", nil] {
            let survey = try visor(mountedAt: place)
            let delete = try survey.state(for: .visor).deleteCommands()
            // No volumes.json, or one recording another volume as Visor's.
            for recorded in [nil, recording("11111111-2222-3333-4444-555555555555")] {
                let error = #expect(throws: DiskVolumesError.self, "\(place ?? "unmounted")") {
                    try VolumeGuard.check(delete, against: survey, recorded: recorded, deleting: [.visor])
                }
                guard case let .wrongTarget(why)? = error else { Issue.record("\(String(describing: error))"); continue }
                #expect(why.contains("may not be Visor's, so nothing was deleted"))
                #expect(why.contains(place.map { "mounted at \($0)" } ?? "isn't mounted"))
            }
        }
    }

    /// The UUID was recorded only when the volume was found named Visor at
    /// /Volumes/Visor (made there, or adopted there): the same volume,
    /// which macOS may since have mounted at "/Volumes/Visor 1" (the path
    /// taken when it mounted) or not at all. Refusing it would strand
    /// Visor's own volume; it's the one the reviewer's UUID rule is for.
    @Test func visorsOwnIsDeletedByItsRecordedUUIDWhereverItsMounted() throws {
        for place in ["/Volumes/Visor 1", nil] {
            let survey = try visor(mountedAt: place)
            let delete = try survey.state(for: .visor).deleteCommands()
            try VolumeGuard.check(delete, against: survey, recorded: recording(Self.visorUUID), deleting: [.visor])
            try VolumeGuard.check(delete, against: survey, recorded: recording(Self.visorUUID.lowercased()), deleting: [.visor])
        }
        // At /Volumes/Visor, with no volumes.json at all.
        let inPlace = try Disks.both()
        try VolumeGuard.check(try inPlace.state(for: .visor).deleteCommands(), against: inPlace, deleting: [.visor])
    }

    @Test func visorIsDeletedByItsUUIDNeverItsDisk() throws {
        let survey = try Disks.both()
        let erase = try survey.state(for: .visor).deleteCommands()
        #expect(erase[0].argv == ["/usr/sbin/diskutil", "apfs", "deleteVolume", Self.visorUUID])
        #expect(throws: DiskVolumesError.self) { try DiskCommand.deleteVolume(.visor, uuid: "disk3s8") }
        #expect(throws: DiskVolumesError.self) { try DiskCommand.deleteVolume(.visor, uuid: "") }

        let byDisk = command("apfs", "deleteVolume", "disk3s8")
        let error = #expect(throws: DiskVolumesError.self) { try VolumeGuard.check([byDisk], against: survey, deleting: [.visor]) }
        #expect(error?.description.contains("deleted by their UUIDs alone") == true)

        // The disks renumbered since the window looked: the UUID still names it.
        var renumbered = survey
        for container in renumbered.containers.indices {
            for volume in renumbered.containers[container].volumes.indices where renumbered.containers[container].volumes[volume].name == "Visor" {
                renumbered.containers[container].volumes[volume].device = "disk3s9"
            }
        }
        for info in renumbered.infos.indices where renumbered.infos[info].volumeName == "Visor" { renumbered.infos[info].device = "disk3s9" }
        try VolumeGuard.check(erase, against: renumbered, deleting: [.visor])

        // Gone since (deleted, or made again with a new UUID): nothing runs.
        var gone = survey
        for container in gone.containers.indices { gone.containers[container].volumes.removeAll { $0.name == "Visor" } }
        let missing = #expect(throws: DiskVolumesError.self) { try VolumeGuard.check(erase, against: gone, deleting: [.visor]) }
        #expect(missing?.description.contains("No APFS volume here has the UUID \(Self.visorUUID)") == true)
    }

    @Test func anArgumentThatIsExactlyAndAndIsRefused() throws {
        let fresh = try Disks.fresh()
        let add = try DiskCommand.addVolume(.visor, container: "disk3", reserve: 0, quota: 20 * ByteSize.gigabyte)
        try VolumeGuard.check([add], against: fresh)
        var joined = add
        joined.arguments[joined.arguments.count - 1] = "&&"
        let both = try Disks.both()
        let delete = try both.state(for: .visor).deleteCommands()
        for (attempt, survey) in [(joined, fresh), (command("apfs", "deleteVolume", "&&"), both),
                                  (command("&&", "apfs", "list"), fresh), (DiskCommand(arguments: delete[0].arguments + ["&&"]), both)] {
            #expect(throws: DiskVolumesError.notAllowed("\(attempt.description) (an argument is exactly &&, "
                                                         + "which would start another command in the administrator prompt's shell)"),
                    "\(attempt)") { try VolumeGuard.check([attempt], against: survey, deleting: [.visor]) }
        }
    }
}
