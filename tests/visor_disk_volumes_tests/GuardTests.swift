// Sessions is never erased or deleted, however the command is made.

import DiskVolumes
import Foundation
import Testing

@Suite struct GuardTests {
    private func command(_ arguments: String...) -> DiskCommand { DiskCommand(arguments: arguments) }

    @Test func sessionsHasNoEraseAndNoDelete() throws {
        #expect(!VolumeRole.sessions.isErasable)
        #expect(throws: DiskVolumesError.self) { try DiskCommand.deleteVolume(.sessions, uuid: "86410F75-D43C-49E6-95C6-B20A5CBB16F2") }
        let sessions = try Disks.both().state(for: .sessions)
        #expect(throws: DiskVolumesError.self) { try sessions.eraseCommands(reserve: 0, quota: 0) }
    }

    @Test func aHandMadeDeleteOrEraseOfSessionsIsRefused() throws {
        for survey in [try Disks.both(), try Disks.caseInsensitiveSessions()] {
            let device = try #require(survey.state(for: .sessions).volume?.device)
            let uuid = try #require(survey.state(for: .sessions).volume?.uuid)
            for attempt in [command("apfs", "deleteVolume", device), command("apfs", "deleteVolume", uuid),
                            command("apfs", "deleteVolume", uuid.lowercased()), command("apfs", "eraseVolume", device, "-name", "Containers"),
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

    @Test func eraseContainersPasses() throws {
        let survey = try Disks.both()
        let state = survey.state(for: .containers)
        let commands = try state.eraseCommands(reserve: 0, quota: 20 * ByteSize.gigabyte)
        #expect(commands.map(\.description) == [
            "diskutil apfs deleteVolume 4EF85269-E4B1-4058-A1FA-E9240A971CC9",
            "diskutil apfs addVolume disk3 Case-sensitive APFS Containers -quota 20000000000b",
        ])
        try VolumeGuard.check(commands, against: survey)
    }

    @Test func onlyAddingAndDeletingContainersRun() throws {
        let survey = try Disks.both()
        let data = command("apfs", "deleteVolume", "disk3s5")
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check([data], against: survey) }
        let unknown = command("apfs", "deleteVolume", "disk9s9")
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check([unknown], against: survey) }
        for other in [command("eraseDisk", "APFS", "x", "disk0"), command("apfs", "list"), command("unmount", "/Volumes/Containers"),
                      command("apfs", "addVolume", "disk3", "APFS", "Other")] {
            #expect(throws: DiskVolumesError.notAllowed(other.description)) { try VolumeGuard.check([other], against: survey) }
        }
        let extra = command("apfs", "addVolume", "disk3", "Case-sensitive APFS", "Containers", "-mountpoint", "/")
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check([extra], against: try Disks.fresh()) }
    }

    @Test func anExistingVolumeIsNeverMadeTwice() throws {
        let survey = try Disks.caseInsensitiveSessions()
        let again = try DiskCommand.addVolume(.sessions, container: "disk3", reserve: 0, quota: 0)
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check([again], against: survey) }
        try VolumeGuard.check([try DiskCommand.addVolume(.containers, container: "disk3", reserve: 0, quota: 0)], against: survey)
        let elsewhere = try DiskCommand.addVolume(.containers, container: "disk9", reserve: 0, quota: 0)
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check([elsewhere], against: survey) }
    }

    // NCH's review of #465: Containers is deleted only when it's Visor's,
    // only by its UUID, and nothing joins a second command in.

    private static let containersUUID = "4EF85269-E4B1-4058-A1FA-E9240A971CC9"

    /// Both volumes, Containers mounted at `place` instead (nil: not mounted).
    private func containers(mountedAt place: String?) throws -> DiskSurvey {
        var survey = try Disks.both()
        let index = try #require(survey.infos.firstIndex { $0.volumeName == "Containers" })
        survey.infos[index].mountPoint = place
        return survey
    }

    private func recording(_ uuid: String) -> VolumesStatus {
        VolumesStatus(updated: Date(), volumes: [], ownVolumes: ["containers": uuid])
    }

    @Test func aContainersThatIsntVisorsIsRefused() throws {
        for place in ["/Volumes/Containers 1", "/Users/someone/Containers", nil] {
            let survey = try containers(mountedAt: place)
            let erase = try survey.state(for: .containers).eraseCommands(reserve: 0, quota: 0)
            // No volumes.json, or one recording another volume as Visor's.
            for recorded in [nil, recording("11111111-2222-3333-4444-555555555555")] {
                let error = #expect(throws: DiskVolumesError.self, "\(place ?? "unmounted")") {
                    try VolumeGuard.check(erase, against: survey, recorded: recorded)
                }
                guard case let .wrongTarget(why)? = error else { Issue.record("\(String(describing: error))"); continue }
                #expect(why.contains("may not be Visor's, so nothing was deleted"))
                #expect(why.contains(place.map { "mounted at \($0)" } ?? "isn't mounted"))
            }
        }
    }

    /// The UUID was recorded only when the volume was found named Containers
    /// at /Volumes/Containers (made there, or adopted there): the same
    /// volume, which macOS may since have mounted at "/Volumes/Containers 1"
    /// (the path taken when it mounted) or not at all. Refusing it would
    /// strand Visor's own volume; it's the one the reviewer's UUID rule is for.
    @Test func visorsOwnContainersIsErasedByItsRecordedUUIDWhereverItsMounted() throws {
        for place in ["/Volumes/Containers 1", nil] {
            let survey = try containers(mountedAt: place)
            let erase = try survey.state(for: .containers).eraseCommands(reserve: 0, quota: 0)
            try VolumeGuard.check(erase, against: survey, recorded: recording(Self.containersUUID))
            try VolumeGuard.check(erase, against: survey, recorded: recording(Self.containersUUID.lowercased()))
        }
        // At /Volumes/Containers, with no volumes.json at all.
        let inPlace = try Disks.both()
        try VolumeGuard.check(try inPlace.state(for: .containers).eraseCommands(reserve: 0, quota: 0), against: inPlace)
    }

    @Test func containersIsDeletedByItsUUIDNeverItsDisk() throws {
        let survey = try Disks.both()
        let erase = try survey.state(for: .containers).eraseCommands(reserve: 0, quota: 0)
        #expect(erase[0].argv == ["/usr/sbin/diskutil", "apfs", "deleteVolume", Self.containersUUID])
        #expect(throws: DiskVolumesError.self) { try DiskCommand.deleteVolume(.containers, uuid: "disk3s8") }
        #expect(throws: DiskVolumesError.self) { try DiskCommand.deleteVolume(.containers, uuid: "") }

        let byDisk = command("apfs", "deleteVolume", "disk3s8")
        let error = #expect(throws: DiskVolumesError.self) { try VolumeGuard.check([byDisk], against: survey) }
        #expect(error?.description.contains("deleted by its UUID alone") == true)

        // The disks renumbered since the window looked: the UUID still names it.
        var renumbered = survey
        for container in renumbered.containers.indices {
            for volume in renumbered.containers[container].volumes.indices where renumbered.containers[container].volumes[volume].name == "Containers" {
                renumbered.containers[container].volumes[volume].device = "disk3s9"
            }
        }
        for info in renumbered.infos.indices where renumbered.infos[info].volumeName == "Containers" { renumbered.infos[info].device = "disk3s9" }
        try VolumeGuard.check(erase, against: renumbered)

        // Gone since (deleted, or made again with a new UUID): nothing runs.
        var gone = survey
        for container in gone.containers.indices { gone.containers[container].volumes.removeAll { $0.name == "Containers" } }
        let missing = #expect(throws: DiskVolumesError.self) { try VolumeGuard.check(erase, against: gone) }
        #expect(missing?.description.contains("No APFS volume here has the UUID \(Self.containersUUID)") == true)
    }

    @Test func anArgumentThatIsExactlyAndAndIsRefused() throws {
        let fresh = try Disks.fresh()
        let add = try DiskCommand.addVolume(.containers, container: "disk3", reserve: 0, quota: 20 * ByteSize.gigabyte)
        try VolumeGuard.check([add], against: fresh)
        var joined = add
        joined.arguments[joined.arguments.count - 1] = "&&"
        let both = try Disks.both()
        let erase = try both.state(for: .containers).eraseCommands(reserve: 0, quota: 0)
        for (attempt, survey) in [(joined, fresh), (command("apfs", "deleteVolume", "&&"), both),
                                  (command("&&", "apfs", "list"), fresh), (DiskCommand(arguments: erase[1].arguments + ["&&"]), both)] {
            let commands = survey == both ? [erase[0], attempt] : [attempt]
            #expect(throws: DiskVolumesError.notAllowed("\(attempt.description) (an argument is exactly &&, "
                                                         + "which would start another command in the administrator prompt's shell)"),
                    "\(attempt)") { try VolumeGuard.check(commands, against: survey) }
        }
    }
}
