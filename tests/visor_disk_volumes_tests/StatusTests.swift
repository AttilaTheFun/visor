// volumes.json, written by Visor Disk Utility and read by Visor.

import DiskVolumes
import Foundation
import Testing

@Suite struct StatusTests {
    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("disk-volumes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func theStatusOfBothRoundTrips() throws {
        let status = VolumesStatus(survey: try Disks.both(), updated: Date(timeIntervalSince1970: 1_795_000_000))
        #expect(status.volumes.map(\.role) == [.sessions, .containers])
        let sessions = try #require(status.record(for: .sessions))
        #expect(sessions.path == "/Volumes/Sessions")
        #expect(sessions.format == "Case-sensitive APFS")
        #expect(sessions.caseSensitive == true)
        let text = String(decoding: try status.encoded(), as: UTF8.self)
        #expect(text.contains(#""caseSensitive" : true"#))
        #expect(try VolumesStatus.decoded(from: status.encoded()) == status)
    }

    @Test func aMissingVolumeHasNoLine() throws {
        let status = VolumesStatus(survey: try Disks.caseInsensitiveSessions(), updated: Date())
        #expect(status.volumes.map(\.role) == [.sessions])
        #expect(status.record(for: .sessions)?.caseSensitive == false)
    }

    @Test func visorFindsThemFromTheFileAndTheMountPoints() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try VolumesStatus(survey: try Disks.both(), updated: Date()).write(to: VolumesStatus.url(inDataDirectory: folder))
        let found = DiskVolumes.locate(dataDirectory: folder) { $0 == "/Volumes/Sessions" }
        #expect(found.sessions.isReady)
        #expect(found.sessions.isCaseSensitive == true)
        #expect(found[.containers].path == "/Volumes/Containers")
        #expect(!found.containers.isReady)
        #expect(found.status?.volumes.count == 2)
    }

    @Test func withNoFileTheMountPointsAlone() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let found = DiskVolumes.locate(dataDirectory: folder) { _ in true }
        #expect(found.status == nil)
        #expect(found.sessions.path == "/Volumes/Sessions")
        #expect(found.sessions.isReady)
        #expect(found.sessions.isCaseSensitive == nil)
    }

    @Test func aFileOfALaterFormatIsSkipped() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try VolumesStatus(version: VolumesStatus.currentVersion + 1, updated: Date(), volumes: [])
            .write(to: VolumesStatus.url(inDataDirectory: folder))
        #expect(DiskVolumes.locate(dataDirectory: folder) { _ in false }.status == nil)
    }

    @Test func mountPoints() throws {
        #expect(DiskVolumes.isMountPoint("/"))
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!DiskVolumes.isMountPoint(folder.path))
        #expect(!DiskVolumes.isMountPoint(folder.appendingPathComponent("missing").path))
    }

    @Test func visorsOwnVolumesAreRecordedAndKept() throws {
        let containers = "4EF85269-E4B1-4058-A1FA-E9240A971CC9"
        let made = VolumesStatus(survey: try Disks.both(), updated: Date())
        #expect(made.ownUUID(for: .containers) == containers)
        #expect(made.ownUUID(for: .sessions) == "86410F75-D43C-49E6-95C6-B20A5CBB16F2")
        #expect(made.record(for: .containers)?.uuid == containers)
        #expect(try VolumesStatus.decoded(from: made.encoded()) == made)

        // Mounted elsewhere since: still Visor's, from the file before.
        var moved = try Disks.both()
        let index = try #require(moved.infos.firstIndex { $0.volumeName == "Containers" })
        moved.infos[index].mountPoint = "/Volumes/Containers 1"
        #expect(VolumesStatus(survey: moved, updated: Date(), previous: made).ownUUID(for: .containers) == containers)
        // With no file before, a Containers found elsewhere isn't taken for Visor's.
        let unknown = VolumesStatus(survey: moved, updated: Date())
        #expect(unknown.ownUUID(for: .containers) == nil)
        #expect(unknown.record(for: .containers)?.uuid == containers)

        // Erased and made again in place: the new one is Visor's.
        var remade = try Disks.both()
        for container in remade.containers.indices {
            for volume in remade.containers[container].volumes.indices where remade.containers[container].volumes[volume].name == "Containers" {
                remade.containers[container].volumes[volume].uuid = "0A0B0C0D-1111-2222-3333-444455556666"
            }
        }
        #expect(VolumesStatus(survey: remade, updated: Date(), previous: made).ownUUID(for: .containers)
            == "0A0B0C0D-1111-2222-3333-444455556666")
    }

    @Test func aFileWrittenBeforeUUIDsIsStillRead() throws {
        let older = #"{"updated":"2026-11-19T10:00:00Z","version":1,"volumes":[{"device":"disk3s8","format":"Case-sensitive APFS","#
            + #""name":"Containers","path":"/Volumes/Containers","quota":0,"reserve":0,"role":"containers","used":0}]}"#
        let status = try VolumesStatus.decoded(from: Data(older.utf8))
        #expect(status.ownVolumes.isEmpty)
        #expect(status.record(for: .containers)?.uuid == nil)
    }
}
