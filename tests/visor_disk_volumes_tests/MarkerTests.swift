// The marker copy-staged leaves and Swap In reads: written and read back
// whole, at a volume's root, as JSON.

import DiskVolumes
import Foundation
import Testing

@Suite struct MarkerTests {
    @Test func theMarkerRoundTrips() throws {
        let marker = ConversionDisks.marker(.sources)
        #expect(try ConversionMarker.decoded(from: marker.encoded()) == marker)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-marker-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(try ConversionMarker.read(atRoot: root) == nil)
        try marker.write(atRoot: root)
        #expect(ConversionMarker.path(atRoot: root) == root + "/.visor-conversion-verified")
        let read = try #require(try ConversionMarker.read(atRoot: root))
        #expect(read == marker)
        try read.check(role: .sources, sourceUUID: ConversionDisks.sourcesUUID.lowercased(), newUUID: ConversionDisks.sourcesNewUUID,
                       now: ConversionDisks.now)
        // What it says, by name, for a person reading it.
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: ConversionMarker.path(atRoot: root))))
            as? [String: Any])
        #expect(Set(json.keys) == ["version", "role", "sourceUUID", "newUUID", "files", "links", "directories", "manifestSHA256",
                                   "sourceListingSHA256", "verified"])
        #expect(json["role"] as? String == "sources")
        #expect(json["verified"] as? String == "2026-11-18T10:56:40Z")
    }

    @Test func anUnreadableOrLaterMarkerIsRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-marker-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Data("not json".utf8).write(to: URL(fileURLWithPath: ConversionMarker.path(atRoot: root)))
        #expect(throws: DiskVolumesError.self) { try ConversionMarker.read(atRoot: root) }
        var later = ConversionDisks.marker(.sessions)
        later.version = ConversionMarker.currentVersion + 1
        let error = #expect(throws: DiskVolumesError.self) {
            try later.check(role: .sessions, sourceUUID: ConversionDisks.sessionsUUID, newUUID: ConversionDisks.sessionsNewUUID, now: ConversionDisks.now)
        }
        #expect(error?.description.contains("later format") == true)
    }
}
