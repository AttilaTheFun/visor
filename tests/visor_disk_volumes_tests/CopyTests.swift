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
            // A hard link within one root entry, which ditto keeps.
            try files.linkItem(atPath: source + "/Claude/abc/notes.md", toPath: source + "/Claude/abc/notes-again.md")
            try files.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source + "/.claude/settings.json")
        }

        /// The person the tests run as: whoever owns what they made.
        var owner: FileOwner {
            let made = (try? FoundationFileInspector().inspect(source)) ?? FileInspection(kind: .directory)
            return FileOwner(uid: made.uid, groups: [made.gid])
        }

        func write(_ text: String, _ path: String, in base: String? = nil) throws {
            try Data(text.utf8).write(to: URL(fileURLWithPath: (base ?? source) + "/" + path))
        }

        func remove() { try? FileManager.default.removeItem(atPath: root) }

        var markerPath: String { ConversionMarker.path(atRoot: copy) }

        func copyAndVerify(replace: Bool = false, inspector: some FileInspecting = FoundationFileInspector(), free: Int64? = nil,
                           said: Said? = nil, run: ([String]) throws -> Void = CopyTests.run) throws -> ConversionMarker {
            try ConversionCopy.copyAndVerify(role: .sessions, from: source, to: copy, sourceUUID: ConversionDisks.sessionsUUID,
                                             newUUID: ConversionDisks.sessionsNewUUID, owner: owner, inspector: inspector,
                                             destinationFree: free, replace: replace, now: { ConversionDisks.now }, run: run,
                                             say: { said?.lines.append($0) })
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
        let commands = try ConversionCopy.commands(from: scratch.source, to: scratch.copy, entries: try ConversionCopy.entries(at: scratch.source),
                                                   inspector: FoundationFileInspector())
        #expect(commands == [
            ["/usr/bin/ditto", scratch.source + "/.claude", scratch.copy + "/.claude"],
            ["/usr/bin/ditto", scratch.source + "/Claude", scratch.copy + "/Claude"],
            ["/bin/cp", "-P", "-p", scratch.source + "/checkouts", scratch.copy + "/checkouts"],
            ["/usr/bin/ditto", scratch.source + "/empty", scratch.copy + "/empty"],
            ["/bin/cp", "-P", "-p", scratch.source + "/outside", scratch.copy + "/outside"],
            ["/usr/bin/ditto", scratch.source + "/top.txt", scratch.copy + "/top.txt"],
        ])

        let marker = try scratch.copyAndVerify()
        #expect(marker.files == 6)
        #expect(marker.links == 4)
        #expect(marker.directories == 5)
        #expect(marker.hardLinks == 1)
        #expect(marker.sourceUUID == ConversionDisks.sessionsUUID && marker.newUUID == ConversionDisks.sessionsNewUUID)
        #expect(marker.verified == ConversionDisks.now)
        #expect(try ConversionMarker.read(atRoot: scratch.copy) == marker)
        let source = try VolumeManifest.make(of: scratch.source, .content)
        #expect(marker.manifestSHA256 == source.sha256)
        #expect(marker.sourceListingSHA256 == (try VolumeManifest.make(of: scratch.source, .listing)).sha256)
        #expect(marker.copyListingSHA256 == (try VolumeManifest.make(of: scratch.copy, .listing)).sha256)
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
        #expect(source.lines.contains { $0.hasPrefix("L Claude u=") && $0.hasSuffix(" checkouts") })
        let top = try FoundationFileInspector().inspect(scratch.source + "/top.txt")
        #expect(source.lines.contains("F \(try VolumeManifest.hash(file: scratch.source + "/top.txt")) \(top.metadata) top.txt"))
        #expect(source.lines.contains { $0.hasPrefix("F ") && $0.contains(" m=640 ") && $0.hasSuffix(" .claude/settings.json") })
        #expect(source.lines.contains("H Claude/abc/notes-again.md\tClaude/abc/notes.md"))
        #expect(source.hardLinks == [["Claude/abc/notes-again.md", "Claude/abc/notes.md"]])
        #expect(source.lines.contains { $0.hasSuffix(" Claude/abc/odd\\nname") })
        #expect(!source.lines.contains { $0.contains(".Spotlight-V100") || $0.hasSuffix(" .fseventsd") })
    }

    /// ditto leaves off the flags of the folder it's given (NCH's run in a
    /// macOS lease: a hidden folder at the root came over unhidden): they're
    /// set after, by chflags, for a folder at the root that has any.
    @Test func aRootFoldersFlagsAreSetAfterItsCopy() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let commands = try ConversionCopy.commands(from: scratch.source, to: scratch.copy, entries: ["empty", "top.txt", "checkouts"],
                                                   inspector: FlaggedInspector(path: scratch.source + "/empty"))
        #expect(commands == [
            ["/usr/bin/ditto", scratch.source + "/empty", scratch.copy + "/empty"],
            ["/usr/bin/chflags", "0100000", scratch.copy + "/empty"],
            ["/usr/bin/ditto", scratch.source + "/top.txt", scratch.copy + "/top.txt"],
            ["/bin/cp", "-P", "-p", scratch.source + "/checkouts", scratch.copy + "/checkouts"],
        ])
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
        #expect(mismatch?.description.contains("- L Claude u=") == true)
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
        #expect(error?.description.contains("- L notes.md u=") == true)
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

    @Test func aModeOrSplitHardLinkInTheCopyIsCaught() throws {
        let mode = try Scratch()
        defer { mode.remove() }
        let changed = #expect(throws: DiskVolumesError.self) {
            try mode.copyAndVerify { argv in
                try CopyTests.run(argv)
                if argv.last == mode.copy + "/.claude" {
                    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: mode.copy + "/.claude/settings.json")
                }
            }
        }
        #expect(changed?.description.contains("MISMATCH") == true)
        #expect(changed?.description.contains(" m=640 ") == true)
        #expect(!FileManager.default.fileExists(atPath: mode.markerPath))

        let split = try Scratch()
        defer { split.remove() }
        let error = #expect(throws: DiskVolumesError.self) {
            try split.copyAndVerify { argv in
                try CopyTests.run(argv)
                if argv.last == split.copy + "/Claude" {
                    // The same bytes, but no longer one file.
                    let again = split.copy + "/Claude/abc/notes-again.md"
                    try FileManager.default.removeItem(atPath: again)
                    try FileManager.default.copyItem(atPath: split.copy + "/Claude/abc/notes.md", toPath: again)
                }
            }
        }
        #expect(error?.description.contains("- H Claude/abc/notes-again.md") == true)
        #expect(!FileManager.default.fileExists(atPath: split.markerPath))
    }

    @Test func anXattrOrACLTheCopyLacksIsCaught() throws {
        // What the Mac's inspector reads, stood in for: the copy's notes.md
        // without the source's extended attribute, or ACL.
        for xattrs in [true, false] {
            let scratch = try Scratch()
            defer { scratch.remove() }
            let inspector = DifferingInspector(path: scratch.copy + "/Claude/abc/notes.md", xattrs: xattrs)
            let error = #expect(throws: DiskVolumesError.self) { try scratch.copyAndVerify(inspector: inspector) }
            #expect(error?.description.contains("MISMATCH") == true)
            #expect(!FileManager.default.fileExists(atPath: scratch.markerPath))
        }
    }

    @Test func whatThePersonCantCopyAsItIsIsListedAndRefused() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.write("x\n", "top-link-target")
        try FileManager.default.linkItem(atPath: scratch.source + "/top-link-target", toPath: scratch.source + "/Claude/shared")
        let inspector = ObstacleInspector(source: scratch.source)
        let error = #expect(throws: DiskVolumesError.self) { try scratch.copyAndVerify(inspector: inspector) }
        let said = error?.description ?? ""
        #expect(said.contains("holds 6 things the person can't copy as they are"))
        #expect(said.contains("Claude/abc/notes.md: owned by uid 4242"))
        #expect(said.contains(".claude/settings.json: group 4343, not one of yours"))
        #expect(said.contains("top.txt: you can't read it"))
        #expect(said.contains("empty: flags only root can set (0x20000)"))
        #expect(said.contains("a hard link to") && said.contains("in another entry at the root"))
        #expect(said.contains("Nothing was copied."))
        #expect(try ConversionCopy.entries(at: scratch.copy).isEmpty, "nothing copied")
        #expect(!FileManager.default.fileExists(atPath: scratch.markerPath))
    }

    @Test func aCopyThatWouldntFitIsRefusedBeforeItStarts() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        // Each file once, the hard link within Claude counted once.
        let needed = try ConversionCopy.bytesNeeded(at: scratch.source, inspector: FoundationFileInspector())
        let texts: [String] = ["hello\n", "{\"a\": 1}\n", "top\n", "a nested system-named folder is copied\n", "two lines\n"]
        let sizes: [Int] = texts.map { $0.utf8.count }
        #expect(needed == Int64(sizes.reduce(0, +)))
        let error = #expect(throws: DiskVolumesError.self) { try scratch.copyAndVerify(free: 1_000_000) }
        #expect(error?.description.contains("The copy needs about 100 MB") == true)
        #expect(try ConversionCopy.entries(at: scratch.copy).isEmpty, "nothing copied")
        try scratch.copyAndVerify(free: 10_000_000_000)
    }

    @Test func whatsLeftOutAndLinksThatNeedCaseInsensitivityAreSaid() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try FileManager.default.createDirectory(atPath: scratch.source + "/.Trashes/501", withIntermediateDirectories: true)
        let said = Said()
        try scratch.copyAndVerify(said: said)
        #expect(said.lines.contains { $0.hasPrefix("left out of the copy, as the system's own: .Spotlight-V100 (1 entries), .Trashes (1 entries), "
            + ".fseventsd (1 entries).") && $0.contains("The volume's Trash (.Trashes)") })
        // A link whose target differs in case: found on a case-insensitive
        // volume, not on the copy (stood in for by a folder with the
        // target's other case).
        let root = scratch.root
        for side in ["ci", "cs"] { try FileManager.default.createDirectory(atPath: "\(root)/\(side)", withIntermediateDirectories: true) }
        try Data().write(to: URL(fileURLWithPath: "\(root)/ci/Notes.md"))
        try Data().write(to: URL(fileURLWithPath: "\(root)/ci/notes.md"))
        try Data().write(to: URL(fileURLWithPath: "\(root)/cs/Notes.md"))
        for side in ["ci", "cs"] {
            try FileManager.default.createSymbolicLink(atPath: "\(root)/\(side)/readme", withDestinationPath: "notes.md")
            try FileManager.default.createSymbolicLink(atPath: "\(root)/\(side)/fine", withDestinationPath: "Notes.md")
        }
        #expect(try ConversionCopy.caseDependentLinks(source: "\(root)/ci", copy: "\(root)/cs", inspector: FoundationFileInspector()) == ["readme"])
    }
}

/// What copy-staged said, a line each.
final class Said {
    var lines: [String] = []
}

/// Foundation's inspector, with one path hidden (UF_HIDDEN) and a flag
/// the system keeps for itself (UF_TRACKED), which isn't copied.
private struct FlaggedInspector: FileInspecting {
    let path: String

    func inspect(_ path: String) throws -> FileInspection {
        var file = try FoundationFileInspector().inspect(path)
        if path == self.path { file.flags = 0x8000 | 0x40 }
        return file
    }
}

/// Foundation's inspector, but for one path whose extended attributes or
/// ACL read differently.
private struct DifferingInspector: FileInspecting {
    let path: String
    let xattrs: Bool

    func inspect(_ path: String) throws -> FileInspection {
        var file = try FoundationFileInspector().inspect(path)
        let said = path == self.path ? "differs" : "-"
        if xattrs { file.xattrs = said } else { file.acl = said }
        return file
    }
}

/// Foundation's inspector, with what the person can't copy as it is: a
/// file of another owner, one of another group, an unreadable one, and a
/// folder with a flag only root can set.
private struct ObstacleInspector: FileInspecting {
    let source: String

    func inspect(_ path: String) throws -> FileInspection {
        var file = try FoundationFileInspector().inspect(path)
        switch path {
        case source + "/Claude/abc/notes.md", source + "/Claude/abc/notes-again.md": file.uid = 4242
        case source + "/.claude/settings.json": file.gid = 4343
        case source + "/top.txt": file.readable = false
        case source + "/empty": file.flags = 0x0002_0000
        default: break
        }
        return file
    }
}
