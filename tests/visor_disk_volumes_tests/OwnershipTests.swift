// A volume made as an administrator is root's at its root: Visor Disk
// Utility gives its mount point to the person who made it, in the same
// prompt, as Nimbus gives its own; and an adopted one that isn't theirs is
// put right by its Fix alone. The guard lets chown and chmod run so and no
// other way.

import DiskVolumes
import Foundation
import Testing

@Suite struct OwnershipTests {
    @Test func eachRoleIsMadeAndGivenToThePerson() throws {
        let fresh = try Disks.fresh()
        for role in VolumeRole.allCases {
            let made = try fresh.state(for: role).createCommands(reserve: 0, quota: 0, user: "someone")
            #expect(Array(made.prefix(3).map(\.description).dropFirst())
                    == ["chown someone:staff \(role.mountPoint)", "chmod 775 \(role.mountPoint)"], "\(role)")
            try VolumeGuard.check(made, against: fresh, user: "someone")
        }
        #expect(throws: DiskVolumesError.self) { try fresh.state(for: .visor).createCommands(reserve: 0, quota: 0, user: "-R") }
        #expect(throws: DiskVolumesError.self) { try fresh.state(for: .visor).createCommands(reserve: 0, quota: 0, user: "a b") }
    }

    @Test func anAdoptedVolumesOwnerIsChangedByItsFixAlone() throws {
        let both = try Disks.both()
        let fix = try both.state(for: .visor).ownershipCommands(user: "someone")
        #expect(fix.map(\.description) == ["chown someone:staff /Volumes/Visor", "chmod 775 /Volumes/Visor"])
        // Adopted, and not named for Fix: refused, whoever asks.
        let error = #expect(throws: DiskVolumesError.self) { try VolumeGuard.check(fix, against: both, user: "someone") }
        #expect(error?.description.contains("changed only by its Fix") == true)
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check(fix, against: both, user: "someone", fixing: [.sessions]) }
        try VolumeGuard.check(fix, against: both, user: "someone", fixing: [.visor])
        // Not Visor's own (mounted elsewhere): no Fix.
        var moved = both
        let index = try #require(moved.infos.firstIndex { $0.volumeName == "Visor" })
        moved.infos[index].mountPoint = "/Volumes/Visor 1"
        #expect(throws: DiskVolumesError.self) { try moved.state(for: .visor).ownershipCommands(user: "someone") }
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check(fix, against: moved, user: "someone", fixing: [.visor]) }
    }

    @Test func chownAndChmodRunAsExactlyThatAndNoOtherWay() throws {
        let fresh = try Disks.fresh()
        let add = try DiskCommand.addVolume(.visor, container: "disk3", reserve: 0, quota: 0)
        func refused(_ command: DiskCommand, user: String? = "someone") {
            #expect(throws: DiskVolumesError.self, "\(command)") { try VolumeGuard.check([add, command], against: fresh, user: user) }
        }
        let chown = DiskCommand.chown, chmod = DiskCommand.chmod
        refused(DiskCommand(program: chown, arguments: ["someone:staff", "/"]))
        refused(DiskCommand(program: chown, arguments: ["-R", "someone:staff", "/Volumes/Visor"]))
        refused(DiskCommand(program: chown, arguments: ["someone:staff", "/Volumes/Visor/Data"]))
        refused(DiskCommand(program: chown, arguments: ["root:staff", "/Volumes/Visor"]), user: "someone")
        refused(DiskCommand(program: chown, arguments: ["other:staff", "/Volumes/Visor"]), user: "someone")
        refused(DiskCommand(program: chown, arguments: ["someone:wheel", "/Volumes/Visor"]))
        refused(DiskCommand(program: chown, arguments: ["someone:staff", "/Volumes/Visor"]), user: nil)
        refused(DiskCommand(program: chmod, arguments: ["777", "/Volumes/Visor"]))
        refused(DiskCommand(program: chmod, arguments: ["-R", "775", "/Volumes/Visor"]))
        refused(DiskCommand(program: chmod, arguments: ["775", "/"]))
        // Made in the same run: Sessions isn't, here.
        refused(DiskCommand(program: chown, arguments: ["someone:staff", "/Volumes/Sessions"]))
        // A chown found on a PATH is never run.
        refused(DiskCommand(program: "/usr/bin/chown", arguments: ["someone:staff", "/Volumes/Visor"]))
        // Before the addVolume: not made yet.
        let early = try DiskCommand.ownership(.visor, user: "someone")
        #expect(throws: DiskVolumesError.self) { try VolumeGuard.check(early + [add], against: fresh, user: "someone") }
        try VolumeGuard.check([add] + early, against: fresh, user: "someone")
    }
}
