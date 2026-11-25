// Sessions is never erased or deleted, however the command is made; and no
// volume of Visor's is ever deleted: Visor Disk Utility only creates the
// volumes and checks them (Logan, 24 Nov 2026).

import DiskVolumes
import Foundation
import Testing

@Suite struct GuardTests {
    private func command(_ arguments: String...) -> DiskCommand { DiskCommand(arguments: arguments) }

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

    @Test func noVolumeOfVisorsIsEverDeleted() throws {
        let survey = try Disks.both()
        let visor = try #require(survey.state(for: .visor).volume)
        for attempt in [command("apfs", "deleteVolume", visor.uuid), command("apfs", "deleteVolume", visor.device),
                        command("apfs", "eraseVolume", visor.device, "-name", "Visor"), command("apfs", "deleteVolume", "disk3s5")] {
            #expect(throws: DiskVolumesError.notAllowed(attempt.description), "\(attempt)") { try VolumeGuard.check([attempt], against: survey) }
        }
    }

    @Test func onlyAddingVisorsOwnRuns() throws {
        let survey = try Disks.both()
        for other in [command("eraseDisk", "APFS", "x", "disk0"), command("apfs", "list"), command("unmount", "/Volumes/Visor"),
                      command("apfs", "addVolume", "disk3", "APFS", "Other"), command("rename", "disk3s7", "Sessions-old"),
                      command("mount", "disk3s7")] {
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

    @Test func anArgumentThatIsExactlyAndAndIsRefused() throws {
        let fresh = try Disks.fresh()
        let add = try DiskCommand.addVolume(.visor, container: "disk3", reserve: 0, quota: 20 * ByteSize.gigabyte)
        try VolumeGuard.check([add], against: fresh)
        var joined = add
        joined.arguments[joined.arguments.count - 1] = "&&"
        let both = try Disks.both()
        let fix = try both.state(for: .visor).ownershipCommands(user: "someone")
        for (attempt, survey) in [(joined, fresh), (command("apfs", "deleteVolume", "&&"), both),
                                  (command("&&", "apfs", "list"), fresh),
                                  (DiskCommand(program: fix[0].program, arguments: fix[0].arguments + ["&&"]), both)] {
            #expect(throws: DiskVolumesError.notAllowed("\(attempt.description) (an argument is exactly &&, "
                                                         + "which would start another command in the administrator prompt's shell)"),
                    "\(attempt)") { try VolumeGuard.check([attempt], against: survey, user: "someone", fixing: [.visor]) }
        }
    }
}
