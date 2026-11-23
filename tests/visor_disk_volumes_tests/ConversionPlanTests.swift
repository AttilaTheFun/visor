// A case-insensitive Sessions or Sources converted: the commands Stage,
// Swap In and unswap plan from the disks, and each refusal.

import DiskVolumes
import Foundation
import Testing

@Suite struct ConversionPlanTests {
    private let now = ConversionDisks.now

    @Test func stageMakesACaseSensitiveCopyWithTheVolumesOwnQuotaAndReserve() throws {
        let mini = ConversionDisks.mini()
        #expect(try ConversionPlanner.stageCommands(.sessions, in: mini, user: "logan").map(\.description) == [
            "diskutil apfs addVolume disk3 Case-sensitive APFS Sessions-new -quota 40000000000b",
            "chown logan:staff /Volumes/Sessions-new",
            "chmod 775 /Volumes/Sessions-new",
        ])
        #expect(try ConversionPlanner.stageCommands(.sources, in: mini, user: "logan")[0].argv == [
            "/usr/sbin/diskutil", "apfs", "addVolume", "disk3", "Case-sensitive APFS", "Sources-new", "-quota", "120000000000b",
        ])
        // A reserve, where the volume has one, and no quota where it has none.
        var reserved = mini
        reserved.containers[0].volumes[2].reserve = 20 * ByteSize.gigabyte
        reserved.containers[0].volumes[2].quota = 0
        // With no quota of its own, the copy's is the container's free
        // space less a tenth (at least 20 GB), in whole 10 GB: 408 GB free, 360 GB.
        #expect(try ConversionPlanner.stageCommands(.sessions, in: reserved, user: "logan")[0].description
                == "diskutil apfs addVolume disk3 Case-sensitive APFS Sessions-new -reserve 20000000000b -quota 360000000000b")
        let volume = APFSVolume(device: "disk3s7", name: "Sessions")
        #expect(ConversionPlanner.stagedQuota(volume, container: APFSContainer(reference: "disk3", free: 100 * ByteSize.gigabyte))
                == 80 * ByteSize.gigabyte)
        #expect(ConversionPlanner.stagedQuota(volume, container: APFSContainer(reference: "disk3", free: 25 * ByteSize.gigabyte))
                == 10 * ByteSize.gigabyte)
        #expect(ConversionPlanner.status(.sessions, in: mini, marker: nil, now: now).canStage)
    }

    @Test func stageIsRefusedWithoutTheVolumeOrWithNothingToConvert() throws {
        // No Sessions.
        var missing = ConversionDisks.mini()
        missing.containers[0].volumes.removeAll { $0.name == "Sessions" }
        missing.infos.removeAll { $0.volumeName == "Sessions" }
        expectRefusal("There's no Sessions volume mounted at /Volumes/Sessions") {
            try ConversionPlanner.stageCommands(.sessions, in: missing, user: "logan")
        }
        // Sessions mounted elsewhere is no source either.
        var elsewhere = ConversionDisks.mini()
        elsewhere.infos[0].mountPoint = "/Volumes/Sessions 1"
        expectRefusal("There's no Sessions volume mounted at /Volumes/Sessions") {
            try ConversionPlanner.stageCommands(.sessions, in: elsewhere, user: "logan")
        }
        // Already case-sensitive (the VM's, as Visor Disk Utility made it).
        let made = try Disks.both()
        expectRefusal("Case-sensitive APFS already: nothing to convert") {
            try ConversionPlanner.stageCommands(.sessions, in: made, user: "logan")
        }
        #expect(ConversionPlanner.status(.sessions, in: made, marker: nil, now: now).phase == .converted)
        // Visor is never converted.
        expectRefusal("only Sessions and Sources are") { try ConversionPlanner.stageCommands(.visor, in: ConversionDisks.mini(), user: "logan") }
    }

    @Test func stageIsRefusedOnceStagedAndShownAsStaged() throws {
        let staged = ConversionDisks.staged([.sessions])
        expectRefusal("Sessions-new exists already (disk3s10): it's staged") {
            try ConversionPlanner.stageCommands(.sessions, in: staged, user: "logan")
        }
        let status = ConversionPlanner.status(.sessions, in: staged, marker: nil, now: now)
        #expect(status.phase == .staged(.notCopied))
        #expect(status.staged?.device == "disk3s10")
        #expect(status.summary.contains("waiting for copy-staged sessions"))
        // Sources isn't, and can be.
        #expect(try ConversionPlanner.stageCommands(.sources, in: staged, user: "logan").count == 3)
    }

    @Test func stageIsRefusedWithAKeptVolumeAFolderInTheWayOrNoRoom() throws {
        var kept = ConversionDisks.mini()
        kept.containers[0].volumes.append(APFSVolume(device: "disk3s12", name: "Sessions-old-ci", uuid: "66666666-6666-4666-8666-666666666666"))
        expectRefusal("Sessions-old-ci exists already (disk3s12)") { try ConversionPlanner.stageCommands(.sessions, in: kept, user: "logan") }
        var folder = ConversionDisks.mini()
        folder.foldersInTheWay = ["/Volumes/Sessions-new"]
        expectRefusal("/Volumes/Sessions-new is taken already") { try ConversionPlanner.stageCommands(.sessions, in: folder, user: "logan") }
        let full = ConversionDisks.mini(free: 2 * ByteSize.gigabyte)
        expectRefusal("disk3 has 2 GB free; a copy of Sessions needs about 4.6 GB") {
            try ConversionPlanner.stageCommands(.sessions, in: full, user: "logan")
        }
        expectRefusal("isn't a user's name") { try ConversionPlanner.stageCommands(.sessions, in: ConversionDisks.mini(), user: "-R") }
    }

    @Test func swapRenamesTheOldAwayAndTheCopyIntoPlaceByDisk() throws {
        let staged = ConversionDisks.staged()
        let marker = ConversionDisks.marker(.sessions)
        #expect(try ConversionPlanner.swapCommands(.sessions, in: staged, marker: marker, now: now).map(\.argv) == [
            ["/usr/sbin/diskutil", "rename", "disk3s7", "Sessions-old-ci"],
            ["/usr/sbin/diskutil", "unmount", "disk3s7"],
            ["/usr/sbin/diskutil", "rename", "disk3s10", "Sessions"],
            ["/usr/sbin/diskutil", "unmount", "disk3s10"],
            ["/usr/sbin/diskutil", "mount", "disk3s10"],
        ])
        #expect(try ConversionPlanner.swapCommands(.sources, in: staged, marker: ConversionDisks.marker(.sources), now: now).map(\.description) == [
            "diskutil rename disk3s8 Sources-old-ci", "diskutil unmount disk3s8",
            "diskutil rename disk3s11 Sources", "diskutil unmount disk3s11", "diskutil mount disk3s11",
        ])
        #expect(ConversionPlanner.status(.sessions, in: staged, marker: marker, now: now).canSwap)
    }

    @Test func swapIsRefusedWithoutAFreshMatchingMarker() throws {
        let staged = ConversionDisks.staged()
        expectRefusal("Sessions-new has no .visor-conversion-verified: it hasn't been copied and verified. Run copy-staged sessions first") {
            try ConversionPlanner.swapCommands(.sessions, in: staged, marker: nil, now: now)
        }
        let stale = ConversionDisks.marker(.sessions, minutesOld: 121)
        expectRefusal("verified 121 minutes ago, more than 120") {
            try ConversionPlanner.swapCommands(.sessions, in: staged, marker: stale, now: now)
        }
        try ConversionPlanner.swapCommands(.sessions, in: staged, marker: ConversionDisks.marker(.sessions, minutesOld: 119), now: now)
        let ahead = ConversionDisks.marker(.sessions, minutesOld: -10)
        expectRefusal("ahead of this Mac's clock") { try ConversionPlanner.swapCommands(.sessions, in: staged, marker: ahead, now: now) }
        var otherSource = ConversionDisks.marker(.sessions)
        otherSource.sourceUUID = ConversionDisks.sourcesUUID
        expectRefusal("marker names the source \(ConversionDisks.sourcesUUID), but /Volumes/Sessions is \(ConversionDisks.sessionsUUID)") {
            try ConversionPlanner.swapCommands(.sessions, in: staged, marker: otherSource, now: now)
        }
        var otherCopy = ConversionDisks.marker(.sessions)
        otherCopy.newUUID = ConversionDisks.sourcesNewUUID
        expectRefusal("marker names the copy \(ConversionDisks.sourcesNewUUID), but Sessions-new is \(ConversionDisks.sessionsNewUUID)") {
            try ConversionPlanner.swapCommands(.sessions, in: staged, marker: otherCopy, now: now)
        }
        expectRefusal("marker is Sources's, not Sessions's") {
            try ConversionPlanner.swapCommands(.sessions, in: staged, marker: ConversionDisks.marker(.sources), now: now)
        }
        // The status says why, and Swap In isn't offered.
        let status = ConversionPlanner.status(.sessions, in: staged, marker: stale, now: now)
        #expect(!status.canSwap)
        guard case let .staged(.refused(why)) = status.phase else { Issue.record("\(status.phase)"); return }
        #expect(why.contains("more than 120"))
    }

    @Test func swapIsRefusedWhenTheDisksArentAsStaged() throws {
        let marker = ConversionDisks.marker(.sessions)
        expectRefusal("There's no Sessions-new: stage it first") {
            try ConversionPlanner.swapCommands(.sessions, in: ConversionDisks.mini(), marker: marker, now: now)
        }
        var unmounted = ConversionDisks.staged()
        unmounted.infos[unmounted.infos.count - 2].mountPoint = nil
        expectRefusal("Sessions-new (disk3s10) isn't mounted at /Volumes/Sessions-new") {
            try ConversionPlanner.swapCommands(.sessions, in: unmounted, marker: marker, now: now)
        }
        var insensitiveCopy = ConversionDisks.staged()
        insensitiveCopy.infos[insensitiveCopy.infos.count - 2].filesystemName = "APFS"
        expectRefusal("Sessions-new is APFS, not case-sensitive") {
            try ConversionPlanner.swapCommands(.sessions, in: insensitiveCopy, marker: marker, now: now)
        }
        // Swapped already: Sessions is the case-sensitive copy, nothing to swap.
        expectRefusal("Case-sensitive APFS already: nothing to convert") {
            try ConversionPlanner.swapCommands(.sessions, in: ConversionDisks.swapped(), marker: marker, now: now)
        }
        var kept = ConversionDisks.staged()
        kept.containers[0].volumes.append(APFSVolume(device: "disk3s12", name: "Sessions-old-ci", uuid: "66666666-6666-4666-8666-666666666666"))
        expectRefusal("Sessions-old-ci exists already (disk3s12): delete it before swapping") {
            try ConversionPlanner.swapCommands(.sessions, in: kept, marker: marker, now: now)
        }
    }

    @Test func unswapPutsTheOldVolumeBackByName() throws {
        let swapped = ConversionDisks.swapped()
        #expect(try ConversionPlanner.unswapCommands(.sessions, in: swapped).map(\.description) == [
            "diskutil rename disk3s10 Sessions-cs-failed", "diskutil unmount disk3s10",
            "diskutil mount disk3s7", "diskutil rename disk3s7 Sessions", "diskutil unmount disk3s7", "diskutil mount disk3s7",
        ])
        // The old one mounted (after a restart, at /Volumes/Sessions-old-ci): no mount first.
        var mounted = swapped
        ConversionDisks.rename(&mounted, "disk3s7", to: "Sessions-old-ci", mountedAt: "/Volumes/Sessions-old-ci")
        #expect(try ConversionPlanner.unswapCommands(.sessions, in: mounted).map(\.description) == [
            "diskutil rename disk3s10 Sessions-cs-failed", "diskutil unmount disk3s10",
            "diskutil rename disk3s7 Sessions", "diskutil unmount disk3s7", "diskutil mount disk3s7",
        ])
        // A swap that stopped part-way (the copy not yet renamed): the old one alone put back.
        var halfway = ConversionDisks.staged()
        ConversionDisks.rename(&halfway, "disk3s7", to: "Sessions-old-ci", mountedAt: nil)
        #expect(try ConversionPlanner.unswapCommands(.sessions, in: halfway).map(\.description) == [
            "diskutil mount disk3s7", "diskutil rename disk3s7 Sessions", "diskutil unmount disk3s7", "diskutil mount disk3s7",
        ])
        let status = ConversionPlanner.status(.sessions, in: swapped, marker: nil, now: now)
        #expect(status.phase == .converted)
        #expect(status.kept.map(\.name) == ["Sessions-old-ci"])
        #expect(status.kept[0].summary == "Sessions-old-ci (disk3s7, not mounted): kept for rollback (Sessions as it was, case-insensitive)")
    }

    /// NCH's review of #506: a swap that stopped after its first rename,
    /// the old volume renamed but still mounted where Visor looks.
    @Test func unswapNamesBackAnOldVolumeStillAtTheMountPoint() throws {
        var stopped = ConversionDisks.staged()
        ConversionDisks.rename(&stopped, "disk3s7", to: "Sessions-old-ci", mountedAt: "/Volumes/Sessions")
        #expect(try ConversionPlanner.unswapCommands(.sessions, in: stopped).map(\.description) == [
            "diskutil rename disk3s7 Sessions", "diskutil unmount disk3s7", "diskutil mount disk3s7",
        ])
    }

    /// NCH's review of #506: days on the converted volume, then unswap,
    /// would bring back stale data; it wants --force when it's changed.
    @Test func unswapWarnsWhenTheConvertedVolumeChangedSinceTheSwap() {
        let note = ConversionNote(role: .sessions, swapped: now, newUUID: ConversionDisks.sessionsNewUUID, oldUUID: ConversionDisks.sessionsUUID,
                                  listingSHA256: "same")
        #expect(ConversionPlanner.unswapWarning(.sessions, note: note, uuid: ConversionDisks.sessionsNewUUID.lowercased(), listing: "same") == nil)
        let changed = ConversionPlanner.unswapWarning(.sessions, note: note, uuid: ConversionDisks.sessionsNewUUID, listing: "other")
        #expect(changed?.contains("Sessions has changed since it was swapped in") == true)
        #expect(changed?.contains("stays on Sessions-cs-failed") == true)
        #expect(changed?.contains("unswap sessions --force") == true)
        for unknown in [nil, ConversionNote(role: .sessions, swapped: now, newUUID: ConversionDisks.sourcesNewUUID, oldUUID: "", listingSHA256: "same")] {
            #expect(ConversionPlanner.unswapWarning(.sessions, note: unknown, uuid: ConversionDisks.sessionsNewUUID, listing: "same")?
                .contains("there's no note of when Sessions") == true)
        }
    }

    @Test func unswapIsRefusedWithoutTheOldVolumeOrWithNothingToUndo() throws {
        expectRefusal("There's no Sessions-old-ci to put back") { try ConversionPlanner.unswapCommands(.sessions, in: ConversionDisks.mini()) }
        // The volume at /Volumes/Sessions case-insensitive: it isn't a converted copy.
        var odd = ConversionDisks.mini()
        odd.containers[0].volumes.append(APFSVolume(device: "disk3s12", name: "Sessions-old-ci", uuid: "66666666-6666-4666-8666-666666666666"))
        expectRefusal("it isn't a converted copy, so there's nothing to undo") { try ConversionPlanner.unswapCommands(.sessions, in: odd) }
        var failed = ConversionDisks.swapped()
        failed.containers[0].volumes.append(APFSVolume(device: "disk3s12", name: "Sessions-cs-failed", uuid: "66666666-6666-4666-8666-666666666666"))
        expectRefusal("Sessions-cs-failed exists already (disk3s12)") { try ConversionPlanner.unswapCommands(.sessions, in: failed) }
    }

    @Test func theCommandLineNamesSessionsSourcesOrBoth() {
        #expect(VolumeRole.conversionRoles("sessions") == [.sessions])
        #expect(VolumeRole.conversionRoles("sources") == [.sources])
        #expect(VolumeRole.conversionRoles("both") == [.sessions, .sources])
        #expect(VolumeRole.conversionRoles("visor") == nil)
        #expect(VolumeRole.conversionRoles("Sessions") == nil)
        #expect(DiskSurvey.devicesToDescribe(in: ConversionDisks.swapped().containers)
                == ["disk3s7", "disk3s8", "disk3s9", "disk3s10", "disk3s11"])
    }

    private func expectRefusal<T>(_ words: String, sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> T) {
        do {
            _ = try body()
            Issue.record("not refused (\(words))", sourceLocation: sourceLocation)
        } catch {
            #expect("\(error)".contains(words), "\(error)", sourceLocation: sourceLocation)
        }
    }
}
