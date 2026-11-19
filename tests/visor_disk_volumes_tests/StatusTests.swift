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
}
