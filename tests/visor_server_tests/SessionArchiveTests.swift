// Session archives (VisorServer+SessionArchive): a session exported as one
// file comes back through an import into the backups store and a restore,
// under its own id on the same conversation, with its memory; uploaded a
// piece at a time as well as by its path. An archive that leads out, is
// more than a move carries, holds too many entries or holds what its offer
// doesn't name is refused, and nothing of it is kept. A restore of an
// imported session that is here already is refused, and touches nothing.
// A conversation past the cap is refused with words that name the file,
// its size, the cap and what would help.

import ClaudeTranscript
import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import VisorSystem
import Testing

extension ServerTests {
@Suite @MainActor final class SessionArchiveTests {
    private var server: VisorServer!
    private var root: URL!
    private var home: URL!
    private var outside: URL!
    private var savedHome: URL!
    private let conversation = "abcdabcd-2222-3333-4444-555555555555"
    private let whole = #"{"type":"user","message":{"content":"Build it"}}"# + "\n" + #"{"type":"assistant","message":{"content":"Built."}}"# + "\n"

    init() async throws {
        TestPlatform.install()
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("visor-archive-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: String(cString: try #require(realpath(made.path, nil))), isDirectory: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        savedHome = ClaudeSessionFiles.home
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        ClaudeSessionFiles.home = home
        outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("sentinel"))
        server = VisorServer(port: 7969)
    }

    isolated deinit {
        ClaudeSessionFiles.home = savedHome
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    private var cwd: URL { home.appendingPathComponent("Developer/app", isDirectory: true) }
    private var project: URL {
        ClaudeSessionFiles.projectsRoot(home: home).appendingPathComponent(ClaudeSessionFiles.projectDirectoryName(for: cwd.path), isDirectory: true)
    }
    private var transcript: URL { project.appendingPathComponent(conversation + ".jsonl") }
    private var memory: URL { project.appendingPathComponent("memory", isDirectory: true) }

    /// A Claude session with its conversation (half a line being written
    /// at its end) and its project's memory.
    @discardableResult
    private func session(_ id: String, title: String = "App") throws -> SessionRecord {
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        try Data((whole + #"{"type":"user","#).utf8).write(to: transcript)
        try Data("remember".utf8).write(to: memory.appendingPathComponent("MEMORY.md"))
        var info = SessionInfo(id: id, agent: .claude, cwd: cwd.path, title: title, created: 0)
        info.model = "opus"
        let record = SessionRecord(info: info, process: ClaudeProcess(cwd: cwd.path, skipPermissions: true, resume: conversation))
        server.sessions.append(record)
        return record
    }

    /// The session exported, as the client reads it: where its archive is
    /// kept for reading, and its name.
    private func exported(_ id: String) async throws -> (url: URL, name: String) {
        let reply = await server.exportSession(id, to: nil)
        let token = try #require(reply.migration, Comment(rawValue: reply.message ?? ""))
        let file = try #require(reply.file)
        let url = try #require(server.migrationsOut[token]?.files[VisorServer.sessionArchiveFileID])
        #expect(VisorServer.fileSize(url) == file.size)
        return (url, file.place)
    }

    private func everything(under folder: URL) -> [String] {
        (FileManager.default.subpaths(atPath: folder.path) ?? []).sorted()
    }

    private func run(_ tool: String, _ arguments: [String]) async -> Int32 {
        await Command.output(ToolPath.resolve(tool) ?? "/usr/bin/" + tool, arguments, errors: true)?.status ?? -1
    }

    /// A session archive made by hand of `entries` (name, text), gzipped:
    /// as a CI job, or someone tampering with one, would write it.
    private func archive(_ entries: [(String, String)]) async throws -> URL {
        let made = root.appendingPathComponent("made-" + UUID().uuidString, isDirectory: true)
        for (name, text) in entries {
            let url = made.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let file = root.appendingPathComponent("made-" + UUID().uuidString + ".visorsession")
        let names = try FileManager.default.contentsOfDirectory(atPath: made.path).sorted()
        #expect(await run("tar", ["-czf", file.path, "-C", made.path] + names) == 0)
        return file
    }

    /// One ustar entry of `name` holding `text`, by hand: a name no honest
    /// tar writes (an absolute one, one through `..`) is kept as it is.
    private func rawEntry(_ name: String, _ text: String) -> Data {
        func field(_ text: String, _ length: Int) -> [UInt8] {
            let bytes = Array(text.utf8.prefix(length))
            return bytes + [UInt8](repeating: 0, count: length - bytes.count)
        }
        func octal(_ value: Int, _ length: Int) -> [UInt8] {
            let digits = String(value, radix: 8)
            return field(String(repeating: "0", count: length - 1 - digits.count) + digits, length)
        }
        let body = Array(text.utf8)
        var header = field(name, 100) + octal(0o644, 8) + octal(0, 8) + octal(0, 8) + octal(body.count, 12) + octal(0, 12)
        header += [UInt8](repeating: 0x20, count: 8) + [0x30] + field("", 100) + field("ustar", 6) + Array("00".utf8)
        header += [UInt8](repeating: 0, count: 512 - header.count)
        let digits = String(header.reduce(0) { $0 + Int($1) }, radix: 8)
        header.replaceSubrange(148..<156, with: Array((String(repeating: "0", count: 6 - digits.count) + digits).utf8) + [0, 0x20])
        return Data(header) + Data(body) + Data(count: (512 - body.count % 512) % 512)
    }

    /// The offer of a session archive made by hand, for `files`.
    private func offerJSON(files: [MigrationFile]) -> String {
        var info = SessionInfo(id: "S", agent: .claude, cwd: cwd.path, title: "Handmade", created: 0)
        info.model = "opus"
        return MigrationOffer(token: "t", from: "CI", session: info, resumeID: conversation, home: home.path, files: files).json.encoded()
    }

    private var transcriptFile: MigrationFile {
        MigrationFile(id: "conversation-0", place: "projects/{project}/\(conversation).jsonl", size: whole.utf8.count, packed: false)
    }

    /// The import refused, with `says` in its words, and nothing kept of it:
    /// no backup, nothing left in the backups store, nothing outside.
    private func refused(_ archive: URL, saying says: String, entryCap: Int = VisorServer.unpackEntryCap,
                         sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let reply = await server.importArchive(at: archive, entryCap: entryCap)
        #expect(reply.type == "error", "imported: \(reply.backup?.path ?? "")", sourceLocation: sourceLocation)
        #expect(reply.message?.contains(says) == true, Comment(rawValue: reply.message ?? ""), sourceLocation: sourceLocation)
        #expect(VisorServer.keptBackups().isEmpty, sourceLocation: sourceLocation)
        #expect(everything(under: VisorServer.backupsFolder).isEmpty, "\(everything(under: VisorServer.backupsFolder))", sourceLocation: sourceLocation)
        #expect((try FileManager.default.contentsOfDirectory(atPath: outside.path)) == ["sentinel"], sourceLocation: sourceLocation)
    }

    // MARK: Round trip

    @Test func testAnExportedSessionIsImportedAndRestoredUnderItsOwnID() async throws {
        try session("s1", title: "App: v2/next")
        let (url, name) = try await exported("s1")
        #expect(name.hasPrefix("App- v2-next-") && name.hasSuffix(".visorsession"), "\(name)")

        // Inside: the one folder, its offer and the agent's own files.
        let listing = await Command.output(ToolPath.resolve("tar") ?? "/usr/bin/tar", ["-tzf", url.path])
        let names = Set((listing?.text ?? "").split(separator: "\n").map { $0.hasSuffix("/") ? String($0.dropLast()) : String($0) })
        #expect(names == ["session", "session/offer.json", "session/conversation-0.jsonl", "session/memory.tgz"], "\(names)")

        let imported = await server.importArchive(at: url, named: name)
        let backup = try #require(imported.backup, Comment(rawValue: imported.message ?? ""))
        #expect(backup.imported)
        #expect(backup.sessions == [SessionBackupItem(id: "s1", title: "App: v2/next", outcome: "Imported.", kept: true)])
        #expect(VisorServer.keptBackups().map(\.path) == [backup.path])
        #expect(VisorServer.keptBackups().first?.imported == true)
        #expect(FileManager.default.fileExists(atPath: url.path), "the archive itself is left as it is")

        // Gone from here, conversation, memory and all: restored.
        server.sessions = []
        try FileManager.default.removeItem(at: project)
        let restored = await server.restore(from: URL(fileURLWithPath: backup.path), only: ["s1"])
        #expect(restored.backup?.sessions.first?.outcome == "Restored.", Comment(rawValue: restored.message ?? ""))
        let record = try #require(server.session("s1"))
        #expect(record.process.resumeID == conversation)
        #expect(record.info.model == "opus")
        #expect(record.notice?.hasPrefix("Restored from a session archive") == true, Comment(rawValue: record.notice ?? ""))
        #expect((try String(contentsOf: transcript, encoding: .utf8)) == whole)
        #expect((try String(contentsOf: memory.appendingPathComponent("MEMORY.md"), encoding: .utf8)) == "remember")
    }

    @Test func testAnArchiveUploadedAPieceAtATimeIsImported() async throws {
        try session("s2")
        let (url, name) = try await exported("s2")
        let bytes = try Data(contentsOf: url)
        var begin = Envelope(type: "import")
        begin.file = MigrationFile(id: "archive", place: name, size: bytes.count, packed: true)
        let begun = server.importUpload(begin)
        let token = try #require(begun.migration, Comment(rawValue: begun.message ?? ""))
        var offset = 0
        while offset < bytes.count {
            var piece = Envelope(type: "import")
            piece.migration = token
            piece.offset = offset
            piece.data = bytes[offset..<min(bytes.count, offset + 100)].base64EncodedString()
            let wrote = server.importWrite(piece)
            offset = try #require(wrote.offset, Comment(rawValue: wrote.message ?? ""))
        }
        // Nothing past the size it began with.
        var past = Envelope(type: "import")
        past.migration = token
        past.offset = bytes.count
        past.data = Data("x".utf8).base64EncodedString()
        #expect(server.importWrite(past).type == "error")
        var finish = Envelope(type: "import")
        finish.migration = token
        let finished = await server.importFinish(finish)
        #expect(finished.backup?.sessions.first?.id == "s2", Comment(rawValue: finished.message ?? ""))
        #expect(server.importsIn.isEmpty)

        // An upload more than an archive holds is refused at its start.
        begin.file?.size = VisorServer.sessionArchiveCap + 1
        let large = server.importUpload(begin)
        #expect(large.message?.contains("a session archive holds at most 4.0 GB") == true, Comment(rawValue: large.message ?? ""))
    }

    @Test func testAnExportToAPathWritesThereAndNeverOverAFile() async throws {
        try session("s3")
        let folder = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wrote = await server.exportSession("s3", to: folder.path)
        let path = try #require(wrote.path, Comment(rawValue: wrote.message ?? ""))
        #expect(path == folder.appendingPathComponent(wrote.file?.place ?? "").path)
        #expect(VisorServer.fileSize(URL(fileURLWithPath: path)) == wrote.file?.size)
        #expect(server.migrationsOut.isEmpty, "nothing kept to read: it is where it was asked to be")
        let again = await server.exportSession("s3", to: path)
        #expect(again.message?.contains("is there already") == true, Comment(rawValue: again.message ?? ""))
        // A session with no conversation yet says so.
        server.sessions.append(SessionRecord(info: SessionInfo(id: "new", agent: .claude, cwd: cwd.path, title: "New", created: 0),
                                             process: ClaudeProcess(cwd: cwd.path, skipPermissions: true, resume: nil)))
        let none = await server.exportSession("new", to: nil)
        #expect(none.message == "“New” has no conversation to export yet: send it a message first.")
    }

    // MARK: Restore

    /// Logan's rule: a session here already is removed first; the restore
    /// is refused, and its conversation, memory and record are as they were.
    @Test func testARestoreOfAnImportedSessionThatIsHereIsRefused() async throws {
        let record = try session("s4")
        let (url, _) = try await exported("s4")
        let backup = try #require(await server.importArchive(at: url).backup)
        try Data("short\n".utf8).write(to: transcript)
        try FileManager.default.removeItem(at: memory)
        let restored = await server.restore(from: URL(fileURLWithPath: backup.path), only: nil)
        let outcome = restored.backup?.sessions.first?.outcome ?? ""
        #expect(outcome == "Not restored: “App” (s4) is on this computer already. Remove it first, then restore it.", Comment(rawValue: outcome))
        #expect((try String(contentsOf: transcript, encoding: .utf8)) == "short\n")
        #expect(!FileManager.default.fileExists(atPath: memory.path))
        #expect(server.sessions.count == 1 && server.session("s4") === record)
    }

    // MARK: Tampered archives

    @Test func testAnArchiveThatLeadsOutIsRefused() async throws {
        let escaping = root.appendingPathComponent("escaping.visorsession")
        var tar = rawEntry("session/offer.json", offerJSON(files: [transcriptFile])) + rawEntry("session/conversation-0.jsonl", whole)
        tar += rawEntry("session/../../outside/evil", "x") + Data(count: 1024)
        try tar.write(to: escaping)
        try await refused(escaping, saying: "it holds an entry that leads out, session/../../outside/evil")

        let absolute = root.appendingPathComponent("absolute.visorsession")
        try (rawEntry("session/offer.json", offerJSON(files: [transcriptFile])) + rawEntry(outside.path + "/evil", "x") + Data(count: 1024))
            .write(to: absolute)
        try await refused(absolute, saying: "it holds an entry at an absolute path")

        // A place that isn't where the agent keeps its conversation.
        let place = try await archive([("session/offer.json", offerJSON(files: [MigrationFile(id: "conversation-0", place: "../../outside/evil.jsonl",
                                                                                                    size: 1, packed: false)])),
                                        ("session/conversation-0.jsonl", "x")])
        try await refused(place, saying: "which is not where the agent keeps its conversation")
    }

    @Test func testAnOversizedFileIsRefused() async throws {
        // Said to be past the cap: refused by the offer's own word.
        var large = transcriptFile
        large.size = VisorServer.migrationFileCap + 1
        let said = try await archive([("session/offer.json", offerJSON(files: [large])), ("session/conversation-0.jsonl", whole)])
        try await refused(said, saying: "and a move carries at most 2.0 GB of a file")
        // Said to be small, and larger: refused by its size.
        var small = transcriptFile
        small.size = 4
        let lying = try await archive([("session/offer.json", offerJSON(files: [small])), ("session/conversation-0.jsonl", whole)])
        try await refused(lying, saying: "its conversation-0.jsonl is \(whole.utf8.count) bytes, and its offer says 4")
    }

    @Test func testAnArchiveOfTooManyEntriesIsRefused() async throws {
        // The archive itself: its folder, offer and files, and no more.
        let many = try await archive([("session/offer.json", offerJSON(files: [transcriptFile])), ("session/conversation-0.jsonl", whole)]
                                     + (0..<20).map { ("session/extra-\($0)", "x") })
        try await refused(many, saying: "it holds more entries (files, folders and links) than the 16 an archive may hold")

        // An archive in it (the memory): held to the cap a restore applies.
        let scratch = root.appendingPathComponent("memory-made", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("memory"), withIntermediateDirectories: true)
        for index in 0..<30 { try Data("m".utf8).write(to: scratch.appendingPathComponent("memory/note-\(index).md")) }
        let packed = root.appendingPathComponent("memory.tgz")
        #expect(await run("tar", ["-czf", packed.path, "-C", scratch.path, "memory"]) == 0)
        let memoryData = try Data(contentsOf: packed)
        let file = MigrationFile(id: "memory", place: "", size: memoryData.count, packed: true)
        let made = root.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: made.appendingPathComponent("session"), withIntermediateDirectories: true)
        try Data(offerJSON(files: [transcriptFile, file]).utf8).write(to: made.appendingPathComponent("session/offer.json"))
        try Data(whole.utf8).write(to: made.appendingPathComponent("session/conversation-0.jsonl"))
        try memoryData.write(to: made.appendingPathComponent("session/memory.tgz"))
        let inner = root.appendingPathComponent("inner.visorsession")
        #expect(await run("tar", ["-czf", inner.path, "-C", made.path, "session"]) == 0)
        try await refused(inner, saying: "its memory.tgz can't be unpacked: it holds more entries", entryCap: 20)
        // Within the cap, the same archive comes.
        #expect(await server.importArchive(at: inner).backup?.sessions.first?.id == "S")
    }

    @Test func testAnArchiveWithWhatItsOfferDoesNotNameIsRefused() async throws {
        let extra = try await archive([("session/offer.json", offerJSON(files: [transcriptFile])), ("session/conversation-0.jsonl", whole),
                                       ("session/notes.txt", "x")])
        try await refused(extra, saying: "it holds notes.txt, which its offer doesn't name")
        let missing = try await archive([("session/offer.json", offerJSON(files: [transcriptFile]))])
        try await refused(missing, saying: "it lacks conversation-0.jsonl, which its offer names")
        let noOffer = try await archive([("session/conversation-0.jsonl", whole)])
        try await refused(noOffer, saying: "it holds no offer.json")
        let notOneFolder = try await archive([("offer.json", offerJSON(files: [transcriptFile])), ("conversation-0.jsonl", whole)])
        try await refused(notOneFolder, saying: "not under session")
        let notAnArchive = root.appendingPathComponent("not.visorsession")
        try Data("hello".utf8).write(to: notAnArchive)
        try await refused(notAnArchive, saying: "it is not an archive tar can read")
    }

    /// A plain tar (a CI job's that didn't gzip it) is taken as tar finds it.
    @Test func testAPlainTarIsImported() async throws {
        let made = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: made.appendingPathComponent("session"), withIntermediateDirectories: true)
        try Data(offerJSON(files: [transcriptFile]).utf8).write(to: made.appendingPathComponent("session/offer.json"))
        try Data(whole.utf8).write(to: made.appendingPathComponent("session/conversation-0.jsonl"))
        let plain = root.appendingPathComponent("plain.visorsession")
        #expect(await run("tar", ["-cf", plain.path, "-C", made.path, "session"]) == 0)
        let imported = await server.importArchive(at: plain)
        #expect(imported.backup?.from == "CI", Comment(rawValue: imported.message ?? ""))
    }

    // MARK: Over the cap

    /// A transcript past the cap (one has been seen at 2.4 GB): the export
    /// is refused before anything is copied, in words that name the file,
    /// its size, the cap and what would help.
    @Test func testAConversationOverTheCapIsRefusedClearly() async throws {
        try session("s5")
        // 2.4 GB, sparse: a byte and a newline at its end.
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seek(toOffset: UInt64(2_400_000_000))
        try handle.write(contentsOf: Data("}\n".utf8))
        try handle.close()
        let reply = await server.exportSession("s5", to: nil)
        let message = reply.message ?? ""
        #expect(reply.type == "error")
        #expect(message.hasPrefix("“App” is too large to move, back up or export: its transcript, \(transcript.path), is 2.2 GB, "
            + "and Visor carries at most 2.0 GB of one file."), Comment(rawValue: message))
        #expect(message.contains("carry on in one (ask this one for a summary to start it with)"), Comment(rawValue: message))
        #expect(server.migrationsOut.isEmpty)
        #expect(everything(under: VisorServer.migrationsFolder).isEmpty, "nothing copied: \(everything(under: VisorServer.migrationsFolder))")
    }

    @Test func testAnArchivesNameIsItsTitleAndDay() {
        let day = Date(timeIntervalSince1970: 1_795_000_000)
        #expect(VisorServer.archiveName(title: "Offline sync", date: day) == "Offline sync-2026-11-18.visorsession")
        #expect(VisorServer.archiveName(title: "../a:b\nc", date: day) == "-a-b-c-2026-11-18.visorsession")
        #expect(VisorServer.archiveName(title: "  ", date: day) == "Session-2026-11-18.visorsession")
    }
}
}
