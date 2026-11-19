// Sessions is never erased or deleted, however the command is made.

import DiskVolumes
import Testing

@Suite struct GuardTests {
    private func command(_ arguments: String...) -> DiskCommand { DiskCommand(arguments: arguments) }

    @Test func sessionsHasNoEraseAndNoDelete() throws {
        #expect(!VolumeRole.sessions.isErasable)
        #expect(throws: DiskVolumesError.self) { try DiskCommand.deleteVolume(.sessions, device: "disk3s7") }
        let sessions = try Disks.both().state(for: .sessions)
        #expect(throws: DiskVolumesError.self) { try sessions.eraseCommands(reserve: 0, quota: 0) }
    }

    @Test func aHandMadeDeleteOrEraseOfSessionsIsRefused() throws {
        for survey in [try Disks.both(), try Disks.caseInsensitiveSessions()] {
            let device = try #require(survey.state(for: .sessions).volume?.device)
            for attempt in [command("apfs", "deleteVolume", device), command("apfs", "eraseVolume", device, "-name", "Containers"),
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
        let attempt = command("apfs", "deleteVolume", "disk3s7")
        #expect(throws: DiskVolumesError.sessionsNeverErased(attempt.description)) { try VolumeGuard.check([attempt], against: survey) }
    }

    @Test func eraseContainersPasses() throws {
        let survey = try Disks.both()
        let state = survey.state(for: .containers)
        let commands = try state.eraseCommands(reserve: 0, quota: 20 * ByteSize.gigabyte)
        #expect(commands.map(\.description) == [
            "diskutil apfs deleteVolume \(state.volume?.device ?? "")",
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
}
