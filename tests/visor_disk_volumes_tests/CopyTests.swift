// copy-staged's copy and check, on scratch folders standing in for the two
// volumes: every entry at the root copied (a link there as a link), every
// file's sha256 and every link's target the same on both sides, the
// system's folders left out, the marker written only when all of it holds;
// and a changed file, a followed link or a source that changed meanwhile
// caught, with no marker. On Linux (no ditto) `cp -a` stands in for ditto.

import DiskVolumes
import Foundation
import Testing

@Suite struct CopyTests {
    private struct Scratch {
        let root: String
        var source: String { root + "/Sessions" }
        var copy: String { root + "/Sessions-new" }

        /// A Sessions with nested folders, files, links inside and at the
        /// root (to a folder, outside the volume, dangling), an empty
        /// folder, a name with a newline, and the system's folders.
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-copy-\(UUID().uuidString)").path
            let files = FileManager.default
            for folder in ["Sessions/Claude/abc/.fseventsd", "Sessions/.claude", "Sessions/empty", "Sessions/.Spotlight-V100/Store-V2",
                           "Sessions/.fseventsd", "Sessions-new/.fseventsd"] {
                try files.createDirectory(atPath: root + "/" + folder, withIntermediateDirectories: true)
            }
            try write("hello\n", "Claude/abc/notes.md")
            try write("{\"a\": 1}\n", ".claude/settings.json")
            try write("top\n", "top.txt")
            try write("a nested system-named folder is copied\n", "Claude/abc/.fseventsd/kept")
            try write("two lines\n", "Claude/abc/odd\nname")
            try write("index\n", ".Spotlight-V100/Store-V2/index")
            try write("event\n", ".fseventsd/0001")
            try files.createSymbolicLink(atPath: source + "/Claude/abc/link-to-notes", withDestinationPath: "notes.md")
            try files.createSymbolicLink(atPath: source + "/Claude/abc/dangling", withDestinationPath: "/nowhere/at/all")
            try files.createSymbolicLink(atPath: source + "/checkouts", withDestinationPath: "Claude")
            try files.createSymbolicLink(atPath: source + "/outside", withDestinationPath: "/etc")
        }

        func write(_ text: String, _ path: String, in base: String? = nil) throws {
            try Data(text.utf8).write(to: URL(fileURLWithPath: (base ?? source) + "/" + path))
        }

        func remove() { try? FileManager.default.removeItem(atPath: root) }

        var markerPath: String { ConversionMarker.path(atRoot: copy) }

        func copyAndVerify(replace: Bool = false, run: ([String]) throws -> Void = CopyTests.run) throws -> ConversionMarker {
            try ConversionCopy.copyAndVerify(role: .sessions, from: source, to: copy, sourceUUID: ConversionDisks.sessionsUUID,
                                             newUUID: ConversionDisks.sessionsNewUUID, replace: replace, now: { ConversionDisks.now }, run: run)
        }
    }

    /// Runs a copy's command; ditto, where there's none (Linux), as `cp -a`.
    static func run(_ argv: [String]) throws {
        var argv = argv
        if argv[0] == ConversionCopy.ditto, !FileManager.default.fileExists(atPath: argv[0]) {
            argv = ["/bin/cp", "-a"] + argv.dropFirst()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DiskVolumesError.failed("\(argv) exited with \(process.terminationStatus)") }
    }

    @Test func everythingIsCopiedCheckedAndMarked() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        // A top-level link is copied as a link; everything else by ditto.
        let commands = ConversionCopy.commands(from: scratch.source, to: scratch.copy, entries: try ConversionCopy.entries(at: scratch.source),
                                               isLink: ConversionCopy.isLink)
        #expect(commands == [
            ["/usr/bin/ditto", scratch.source + "/.claude", scratch.copy + "/.claude"],
            ["/usr/bin/ditto", scratch.source + "/Claude", scratch.copy + "/Claude"],
            ["/bin/cp", "-P", "-p", scratch.source + "/checkouts", scratch.copy + "/checkouts"],
            ["/usr/bin/ditto", scratch.source + "/empty", scratch.copy + "/empty"],
            ["/bin/cp", "-P", "-p", scratch.source + "/outside", scratch.copy + "/outside"],
            ["/usr/bin/ditto", scratch.source + "/top.txt", scratch.copy + "/top.txt"],
        ])

        let marker = try scratch.copyAndVerify()
        #expect(marker.files == 5)
        #expect(marker.links == 4)
        #expect(marker.directories == 5)
        #expect(marker.sourceUUID == ConversionDisks.sessionsUUID && marker.newUUID == ConversionDisks.sessionsNewUUID)
        #expect(marker.verified == ConversionDisks.now)
        #expect(try ConversionMarker.read(atRoot: scratch.copy) == marker)
        let source = try VolumeManifest.make(of: scratch.source, .content)
        #expect(marker.manifestSHA256 == source.sha256)
        #expect(marker.sourceListingSHA256 == (try VolumeManifest.make(of: scratch.source, .listing)).sha256)
        // The marker isn't part of what's compared.
        #expect(try VolumeManifest.make(of: scratch.copy, .content) == source)

        let files = FileManager.default
        #expect(try files.destinationOfSymbolicLink(atPath: scratch.copy + "/checkouts") == "Claude")
        #expect(try files.destinationOfSymbolicLink(atPath: scratch.copy + "/outside") == "/etc")
        #expect(try files.destinationOfSymbolicLink(atPath: scratch.copy + "/Claude/abc/link-to-notes") == "notes.md")
        #expect(try files.destinationOfSymbolicLink(atPath: scratch.copy + "/Claude/abc/dangling") == "/nowhere/at/all")
        #expect(!files.fileExists(atPath: scratch.copy + "/.Spotlight-V100"))
        #expect(!files.fileExists(atPath: scratch.copy + "/.fseventsd/0001"))
        #expect(files.fileExists(atPath: scratch.copy + "/Claude/abc/.fseventsd/kept"))
        #expect(source.lines.contains("L Claude checkouts"))
        #expect(source.lines.contains("F \(try VolumeManifest.hash(file: scratch.source + "/top.txt")) top.txt"))
        #expect(source.lines.contains { $0.hasSuffix(" Claude/abc/odd\\nname") })
        #expect(!source.lines.contains { $0.contains(".Spotlight-V100") || $0.hasSuffix(" .fseventsd") })
    }

    @Test func aChangedFileIsCaughtAndNoMarkerWritten() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let error = #expect(throws: DiskVolumesError.self) {
            try scratch.copyAndVerify { argv in
                try CopyTests.run(argv)
                if argv.last == scratch.copy + "/Claude" { try scratch.write("hellO\n", "Claude/abc/notes.md", in: scratch.copy) }
            }
        }
        #expect(error?.description.contains("MISMATCH") == true)
        #expect(error?.description.contains("Claude/abc/notes.md") == true)
        #expect(!FileManager.default.fileExists(atPath: scratch.markerPath))
    }

    @Test func aFollowedLinkAtTheRootOrInsideIsCaught() throws {
        // ditto given a top-level link copies what it points to.
        let followed = try Scratch()
        defer { followed.remove() }
        let mismatch = #expect(throws: DiskVolumesError.self) {
            try followed.copyAndVerify { argv in
                try CopyTests.run(argv[0] == ConversionCopy.cp && argv.last == followed.copy + "/checkouts"
                    ? ["/bin/cp", "-R", "-H", argv[3], argv[4]] : argv)
            }
        }
        #expect(mismatch?.description.contains("MISMATCH") == true)
        #expect(mismatch?.description.contains("- L Claude checkouts") == true)
        #expect(!FileManager.default.fileExists(atPath: followed.markerPath))
        // A link inside a folder that became a file.
        let flattened = try Scratch()
        defer { flattened.remove() }
        let error = #expect(throws: DiskVolumesError.self) {
            try flattened.copyAndVerify { argv in
                try CopyTests.run(argv)
                if argv.last == flattened.copy + "/Claude" {
                    try FileManager.default.removeItem(atPath: flattened.copy + "/Claude/abc/link-to-notes")
                    try flattened.write("hello\n", "Claude/abc/link-to-notes", in: flattened.copy)
                }
            }
        }
        #expect(error?.description.contains("- L notes.md Claude/abc/link-to-notes") == true)
        #expect(!FileManager.default.fileExists(atPath: flattened.markerPath))
    }

    @Test func aSourceChangedDuringTheCopyIsCaught() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let error = #expect(throws: DiskVolumesError.self) {
            try scratch.copyAndVerify { argv in
                try CopyTests.run(argv)
                // Written again with the same bytes: only its time differs.
                if argv.last == scratch.copy + "/top.txt" {
                    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
                                                          ofItemAtPath: scratch.source + "/top.txt")
                }
            }
        }
        #expect(error?.description.contains("changed while it was copied") == true)
        #expect(!FileManager.default.fileExists(atPath: scratch.markerPath))
    }

    @Test func aFailedCommandStopsTheCopyWithNoMarker() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let error = #expect(throws: DiskVolumesError.self) {
            try scratch.copyAndVerify { argv in
                if argv.last == scratch.copy + "/Claude" { throw DiskVolumesError.failed("ditto: Permission denied") }
                try CopyTests.run(argv)
            }
        }
        #expect(error?.description.contains("The copy failed at /usr/bin/ditto \(scratch.source)/Claude") == true)
        #expect(!FileManager.default.fileExists(atPath: scratch.markerPath))
    }

    @Test func aCopyGoesOntoAnEmptyVolumeUnlessReplaced() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.write("left over\n", "junk.txt", in: scratch.copy)
        try ConversionDisks.marker(.sessions).write(atRoot: scratch.copy)
        let error = #expect(throws: DiskVolumesError.self) { try scratch.copyAndVerify() }
        #expect(error?.description.contains("holds 1 entries already (junk.txt)") == true)
        #expect(error?.description.contains("--replace") == true)
        // The old marker went first: nothing to swap in with.
        #expect(!FileManager.default.fileExists(atPath: scratch.markerPath))
        let marker = try scratch.copyAndVerify(replace: true)
        #expect(!FileManager.default.fileExists(atPath: scratch.copy + "/junk.txt"))
        #expect(try ConversionMarker.read(atRoot: scratch.copy) == marker)
        // Copied again over its own copy, with --replace, the same.
        #expect(try scratch.copyAndVerify(replace: true).manifestSHA256 == marker.manifestSHA256)
    }
}
