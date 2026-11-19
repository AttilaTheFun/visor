// Adopt or create: an existing volume is used as it is, never reformatted.

import DiskVolumes
import Testing

@Suite struct PlannerTests {
    @Test func anExistingCaseInsensitiveSessionsIsAdoptedAndExplained() throws {
        let state = try Disks.caseInsensitiveSessions().state(for: .sessions)
        #expect(state.plan == .adopt)
        #expect(state.volume?.device == "disk3s7")
        #expect(state.path == "/Volumes/Sessions")
        #expect(state.isMountedInPlace)
        #expect(state.isCaseSensitive == false)
        #expect(state.format == "APFS")
        #expect(state.notes.count == 1)
        #expect(state.notes[0].contains("case-insensitive"))
        #expect(state.notes[0].contains("never reformatted"))
        // Nothing would make it again, or erase it.
        #expect(throws: DiskVolumesError.self) { try state.createCommands(reserve: 0, quota: 0) }
        #expect(throws: DiskVolumesError.sessionsNeverErased("Erase Sessions")) { try state.eraseCommands(reserve: 0, quota: 0) }
    }

    @Test func aMissingVolumeIsMadeCaseSensitiveInTheBootContainer() throws {
        let state = try Disks.caseInsensitiveSessions().state(for: .containers)
        #expect(state.plan == .create(container: "disk3"))
        #expect(!state.exists)
        #expect(state.path == "/Volumes/Containers")
        #expect(state.format == "Case-sensitive APFS")
        #expect(state.available == 126_925_406_208)
        let commands = try state.createCommands(reserve: 0, quota: 200 * ByteSize.gigabyte)
        #expect(commands.map(\.argv) == [["/usr/sbin/diskutil", "apfs", "addVolume", "disk3", "Case-sensitive APFS", "Containers",
                                          "-quota", "200000000000b"]])
    }

    @Test func aFreshMacMakesBoth() throws {
        let survey = try Disks.fresh()
        for role in VolumeRole.allCases { #expect(survey.state(for: role).plan == .create(container: "disk3")) }
        let sessions = try survey.state(for: .sessions).createCommands(reserve: 20 * ByteSize.gigabyte, quota: 0)
        #expect(sessions.map(\.description) == ["diskutil apfs addVolume disk3 Case-sensitive APFS Sessions -reserve 20000000000b"])
    }

    @Test func bothAsMadeAreAdoptedWithNoNotes() throws {
        let survey = try Disks.both()
        for role in VolumeRole.allCases {
            let state = survey.state(for: role)
            #expect(state.plan == .adopt)
            #expect(state.isCaseSensitive == true)
            #expect(state.notes.isEmpty)
        }
    }

    @Test func aReserveOverTheQuotaIsRefused() throws {
        let state = try Disks.fresh().state(for: .containers)
        #expect(throws: DiskVolumesError.self) { try state.createCommands(reserve: 10 * ByteSize.gigabyte, quota: 5 * ByteSize.gigabyte) }
    }

    @Test func aVolumeOfTheNameNotMountedIsAdoptedWithANote() throws {
        var survey = try Disks.caseInsensitiveSessions()
        survey.infos[0].mountPoint = nil
        let state = survey.state(for: .sessions)
        #expect(state.plan == .adopt)
        #expect(state.notes.contains { $0.contains("isn't mounted") })
        #expect(state.record?.path == nil)
    }

    @Test func aVolumeOfAnotherNameAtTheMountPointIsAdopted() throws {
        var survey = try Disks.caseInsensitiveSessions()
        survey.containers[0].volumes[2].name = "Shireworks Sessions"
        let state = survey.state(for: .sessions)
        #expect(state.plan == .adopt)
        #expect(state.notes.contains { $0.contains("named Shireworks Sessions") })
    }

    @Test func twoVolumesOfTheNameAreLeftToAPerson() throws {
        var survey = try Disks.fresh()
        survey.containers[0].volumes += [APFSVolume(device: "disk3s7", name: "Sessions"), APFSVolume(device: "disk3s8", name: "Sessions")]
        guard case let .blocked(why) = survey.state(for: .sessions).plan else { Issue.record("not blocked"); return }
        #expect(why.contains("disk3s7, disk3s8"))
    }

    @Test func aFolderAtTheMountPointStopsTheMaking() throws {
        var survey = try Disks.fresh()
        survey.foldersInTheWay = ["/Volumes/Sessions"]
        guard case .blocked = survey.state(for: .sessions).plan else { Issue.record("not blocked"); return }
        #expect(survey.state(for: .containers).plan == .create(container: "disk3"))
    }

    @Test func anotherDisksVolumeAtTheMountPointIsLeftAlone() throws {
        var survey = try Disks.fresh()
        survey.infos = [VolumeInfo(device: "disk6s1", volumeName: "Sessions", mountPoint: "/Volumes/Sessions", filesystemType: "msdos",
                                   filesystemName: "MS-DOS (FAT32)", containerReference: nil)]
        guard case let .blocked(why) = survey.state(for: .sessions).plan else { Issue.record("not blocked"); return }
        #expect(why.contains("not APFS"))
    }

    @Test func availableSpaceCountsTheReserveAndTheQuota() {
        let container = APFSContainer(reference: "disk3", free: 100)
        func state(_ volume: APFSVolume) -> VolumeState {
            VolumeState(role: .containers, plan: .adopt, volume: volume, container: container)
        }
        #expect(state(APFSVolume(device: "d", name: "Containers", used: 10)).available == 100)
        #expect(state(APFSVolume(device: "d", name: "Containers", used: 10, reserve: 50)).available == 140)
        #expect(state(APFSVolume(device: "d", name: "Containers", used: 10, quota: 30)).available == 20)
    }
}
