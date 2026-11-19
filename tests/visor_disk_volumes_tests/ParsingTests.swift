// diskutil's plists, as a macOS 27 VM wrote them, read.

import DiskVolumes
import Foundation
import Testing

@Suite struct ParsingTests {
    @Test func apfsListGivesContainersAndVolumes() throws {
        let containers = try Disks.list(Fixtures.listWithCaseInsensitiveSessions)
        #expect(containers.map(\.reference) == ["disk3", "disk5"])
        let boot = containers[0]
        #expect(boot.capacity == 200_265_433_088)
        #expect(boot.free == 126_925_406_208)
        #expect(boot.volumes.map(\.name) == ["Macintosh HD", "Data", "Sessions"])
        let sessions = try #require(boot.volumes.last)
        #expect(sessions == APFSVolume(device: "disk3s7", name: "Sessions", uuid: "68AEACEE-B314-4A78-ADAF-789D4F4FDA99",
                                       used: 712_704, quota: 0, reserve: 0, roles: []))
        #expect(boot.volumes[0].roles == ["System"])
    }

    @Test func infoOfACaseInsensitiveVolume() throws {
        let info = try Disks.info(Fixtures.infoCaseInsensitiveSessions)
        #expect(info.device == "disk3s7")
        #expect(info.volumeName == "Sessions")
        #expect(info.mountPoint == "/Volumes/Sessions")
        #expect(info.containerReference == "disk3")
        #expect(info.containerFree == 126_925_410_304)
        #expect(info.isAPFS)
        #expect(info.filesystemName == "APFS")
        #expect(!info.isCaseSensitive)
        #expect(info.writable)
    }

    @Test func infoOfTheCaseSensitiveVolumesMade() throws {
        let sessions = try Disks.info(Fixtures.infoSessions)
        #expect(sessions.mountPoint == "/Volumes/Sessions")
        #expect(sessions.filesystemName == "Case-sensitive APFS")
        #expect(sessions.isCaseSensitive)
        let containers = try Disks.info(Fixtures.infoContainers)
        #expect(containers.mountPoint == "/Volumes/Containers")
        #expect(containers.isCaseSensitive)
    }

    @Test func infoOfTheBootVolumeNamesItsContainer() throws {
        let root = try Disks.info(Fixtures.infoRoot)
        #expect(root.mountPoint == "/")
        #expect(root.containerReference == "disk3")
        #expect(!root.writable)
    }

    @Test func quotaAndReserveAsMade() throws {
        let volumes = try Disks.list(Fixtures.listWithBoth)[0].volumes
        let sessions = try #require(volumes.first { $0.name == "Sessions" })
        let containers = try #require(volumes.first { $0.name == "Containers" })
        #expect(sessions.reserve == 5 * ByteSize.gigabyte)
        #expect(sessions.quota == 0)
        #expect(containers.quota == 20 * ByteSize.gigabyte)
    }

    @Test func notAPlistThrows() {
        #expect(throws: DiskVolumesError.self) { try APFSContainer.list(fromPlist: Data("not a plist".utf8)) }
        #expect(throws: DiskVolumesError.self) { try VolumeInfo.from(plist: Data("<plist></plist>".utf8)) }
    }

    @Test func sizes() {
        #expect(ByteSize.argument(20 * ByteSize.gigabyte) == "20000000000b")
        #expect(ByteSize.describe(200 * ByteSize.gigabyte) == "200 GB")
        #expect(ByteSize.describe(1_500_000_000) == "1.5 GB")
        #expect(ByteSize.describe(712_704) == "0 MB")
        #expect(ByteSize.gigabytes("1.5") == 1_500_000_000)
        #expect(ByteSize.gigabytes("") == 0)
        #expect(ByteSize.gigabytes("-1") == nil)
        #expect(ByteSize.gigabytes("lots") == nil)
    }
}
