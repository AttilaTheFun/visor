// The Visor volume left out of Spotlight (and Time Machine, by the person),
// as Nimbus leaves its own: the commands planned when it's made and when
// it's adopted, the guard that lets Spotlight's command at Visor's own
// alone, and what mdutil and tmutil say read back. Sessions and Sources stay
// in both.

import DiskVolumes
import Testing

@Suite struct ExclusionTests {
    @Test func makingVisorTurnsSpotlightOffInTheSamePrompt() throws {
        let fresh = try Disks.fresh()
        let visor = try fresh.state(for: .visor).createCommands(reserve: 0, quota: 200 * ByteSize.gigabyte, user: "someone")
        #expect(visor.map(\.argv) == [
            ["/usr/sbin/diskutil", "apfs", "addVolume", "disk3", "Case-sensitive APFS", "Visor", "-quota", "200000000000b"],
            ["/usr/sbin/chown", "someone:staff", "/Volumes/Visor"],
            ["/bin/chmod", "775", "/Volumes/Visor"],
            ["/usr/bin/mdutil", "-i", "off", "/Volumes/Visor"],
        ])
        #expect(visor.map(\.description).last == "mdutil -i off /Volumes/Visor")
        try VolumeGuard.check(visor, against: fresh, user: "someone")
        // Sessions and Sources: made and given to the person, backed up and indexed.
        for role in [VolumeRole.sessions, .sources] {
            let made = try fresh.state(for: role).createCommands(reserve: 0, quota: 0, user: "someone")
            #expect(made.map(\.program) == ["/usr/sbin/diskutil", "/usr/sbin/chown", "/bin/chmod"], "\(role)")
        }
        // All three in one prompt.
        let all = try VolumeRole.allCases.flatMap { try fresh.state(for: $0).createCommands(reserve: 0, quota: 0, user: "someone") }
        try VolumeGuard.check(all, against: fresh, user: "someone")
    }

    @Test func anAdoptedVisorHasSpotlightTurnedOffWhenItsFoundIndexing() throws {
        let both = try Disks.both()
        let visor = both.state(for: .visor)
        let indexing = VolumeExclusions(timeMachineExcluded: false, spotlightIndexed: true)
        #expect(try visor.exclusionCommands(indexing).map(\.argv) == [["/usr/bin/mdutil", "-i", "off", "/Volumes/Visor"]])
        try VolumeGuard.check(try visor.exclusionCommands(indexing), against: both)
        let unknown = VolumeExclusions(timeMachineExcluded: nil, spotlightIndexed: nil)
        #expect(try visor.exclusionCommands(unknown).count == 1, "not known: turned off again, which is harmless")
        let off = VolumeExclusions(timeMachineExcluded: true, spotlightIndexed: false)
        #expect(try visor.exclusionCommands(off).isEmpty)
        // Sessions, whatever Spotlight does there: nothing.
        #expect(try both.state(for: .sessions).exclusionCommands(indexing).isEmpty)
        // A Visor mounted elsewhere isn't known to be Visor's own: nothing.
        var moved = both
        let index = try #require(moved.infos.firstIndex { $0.volumeName == "Visor" })
        moved.infos[index].mountPoint = "/Volumes/Visor 1"
        #expect(try moved.state(for: .visor).exclusionCommands(indexing).isEmpty)
    }

    @Test func spotlightsCommandRunsOnVisorsOwnAlone() throws {
        let both = try Disks.both()
        let off = try DiskCommand.spotlightOff(.visor)
        try VolumeGuard.check([off], against: both)
        #expect(throws: DiskVolumesError.self) { try DiskCommand.spotlightOff(.sessions) }
        for other in [DiskCommand(program: DiskCommand.mdutil, arguments: ["-i", "off", "/Volumes/Sessions"]),
                      DiskCommand(program: DiskCommand.mdutil, arguments: ["-i", "off", "/"]),
                      DiskCommand(program: DiskCommand.mdutil, arguments: ["-E", "/Volumes/Visor"]),
                      DiskCommand(program: DiskCommand.mdutil, arguments: ["-i", "off", "/Volumes/Visor", "/Volumes/Sessions"]),
                      DiskCommand(program: "/usr/bin/tmutil", arguments: ["addexclusion", "-v", "/Volumes/Visor"])] {
            #expect(throws: DiskVolumesError.notAllowed(other.description), "\(other)") { try VolumeGuard.check([other], against: both) }
        }
        // No Visor volume, or one that isn't Visor's own, mounted there: refused.
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check([off], against: try Disks.caseInsensitiveSessions()) }
        var renamed = both
        for container in renamed.containers.indices {
            for volume in renamed.containers[container].volumes.indices where renamed.containers[container].volumes[volume].name == "Visor" {
                renamed.containers[container].volumes[volume].name = "Someone's"
            }
        }
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check([off], against: renamed) }
    }

    @Test func whatTheToolsSayIsReadBack() {
        #expect(VolumeExclusions.timeMachineExcluded(isexcluded: "[Excluded]    /Volumes/Visor\n") == true)
        #expect(VolumeExclusions.timeMachineExcluded(isexcluded: "[Included]    /Volumes/Visor\n") == false)
        #expect(VolumeExclusions.timeMachineExcluded(isexcluded: "tmutil: no such file\n") == nil)
        #expect(VolumeExclusions.spotlightIndexed(mdutilStatus: "/Volumes/Visor:\n\tIndexing disabled.\n") == false)
        #expect(VolumeExclusions.spotlightIndexed(mdutilStatus: "/Volumes/Visor:\n\tIndexing enabled. \n") == true)
        #expect(VolumeExclusions.spotlightIndexed(mdutilStatus: "/Volumes/Visor:\n\tError: unknown indexing state.\n") == nil)
        #expect(VolumeExclusions(timeMachineExcluded: true, spotlightIndexed: false).summary
            == "Not backed up by Time Machine · Not indexed by Spotlight")
        #expect(VolumeExclusions(timeMachineExcluded: true, spotlightIndexed: false).isComplete)
        #expect(VolumeExclusions(timeMachineExcluded: false, spotlightIndexed: nil).summary == "Backed up by Time Machine · Spotlight unknown")
        #expect(!VolumeExclusions(timeMachineExcluded: false, spotlightIndexed: false).isComplete)
    }
}
