// A move's offer is the other server's word, and a server compromised or
// wrong could name `..`, an absolute path, a `/` inside an id, an empty or
// overlong id, a place that is the agent's settings, or an archive whose
// entries lead out or whose links do: the plan refuses such an offer, a
// write refuses such an id, the finish such a place, and an archive (the
// conversation's folder, the memory) is refused unless it holds that one
// folder and nothing in it leads out of it; nothing is written outside the
// move's folder, the agent's place for the conversation, or the session's
// new folder. An archive's own links that stay inside it still come. And an
// archive unpacks to no more than a move carries: refused before when its
// listing says more, stopped while it unpacks when it writes more.

import ClaudeTranscript
import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import VisorSystem
import Testing

extension ServerTests {
@Suite @MainActor final class MigrationContainmentTests {
    private var server: VisorServer!
    private var root: URL!
    private var home: URL!
    private var outside: URL!
    private var savedHome: URL!
    private let conversation = "11111111-2222-3333-4444-555555555555"
    private let hostileIDs = ["..", "../x", "/etc/x", "a/b", "", String(repeating: "a", count: 300), ".", "-x", "../../outside/evil"]

    init() async throws {
        TestPlatform.install()
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("visor-migration-containment-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: String(cString: try #require(realpath(made.path, nil))), isDirectory: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        savedHome = ClaudeSessionFiles.home
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        ClaudeSessionFiles.home = home
        // A folder no move may touch, with a file in it to see it is left be.
        outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("sentinel"))
        server = VisorServer(port: 7974)
    }

    isolated deinit {
        ClaudeSessionFiles.home = savedHome
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    /// Every path under the test's root, to see nothing more was made.
    private func everything() -> Set<String> {
        var found: Set<String> = []
        var folders = [root.path]
        while let folder = folders.popLast() {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
                let path = folder + "/" + name
                found.insert(path)
                if (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeDirectory { folders.append(path) }
            }
        }
        return found
    }

    private func outsideIsAsItWas() throws {
        #expect((try FileManager.default.contentsOfDirectory(atPath: outside.path)) == ["sentinel"])
        #expect((try String(contentsOf: outside.appendingPathComponent("sentinel"), encoding: .utf8)) == "keep")
    }

    private func info(cwd: String) -> SessionInfo {
        SessionInfo(id: "S", agent: .claude, cwd: cwd, title: "Moving", created: 0)
    }

    private func offer(resume: String? = nil, cwd: String? = nil, files: [MigrationFile] = []) -> MigrationOffer {
        MigrationOffer(token: "t", from: "Elsewhere", session: info(cwd: cwd ?? home.appendingPathComponent("Developer/app").path),
                       resumeID: resume ?? conversation, home: home.path, files: files)
    }

    /// A move as a plan leaves it, made here directly (as if a plan had
    /// taken it), so each step's own checks are what is tried: the
    /// session's new folder is the offer's folder here.
    private func move(_ offer: MigrationOffer) throws -> URL {
        let folder = VisorServer.migrationsFolder.appendingPathComponent("in-p", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        server.migrationsIn["p"] = IncomingMigration(offer: offer, plan: MigrationPlan(id: "p", cwd: offer.session.cwd, agentInstalled: true),
                                                     folder: folder, created: Date(), sessionID: "moved")
        return folder
    }

    private func write(_ id: String, _ data: Data, at offset: Int = 0) -> Envelope {
        var e = Envelope(type: "migration")
        e.migration = "p"
        e.file = MigrationFile(id: id, place: "", size: data.count, packed: false)
        e.offset = offset
        e.data = data.base64EncodedString()
        return server.migrationWrite(e)
    }

    private func plan(_ offer: MigrationOffer) async -> Envelope {
        var planning = Envelope(type: "migration")
        planning.offer = offer
        return await server.migrationPlan(planning)
    }

    /// One entry of a tar archive: a file with `text`, a folder, or a link
    /// to `link`; or, with `kind`, any other (`1` a hard link to `link`,
    /// `3` a character device, `6` a fifo). `mode`, else 0755 or 0644.
    private struct Entry {
        var name: String
        var text = ""
        var link: String?
        var folder = false
        var kind: Character?
        var mode: Int?
    }

    /// A gzipped tar of `entries`, written as ustar by hand so that it can
    /// hold what no honest tar makes.
    private func tarball(_ entries: [Entry]) async throws -> Data {
        var tar = Data()
        func field(_ text: String, _ length: Int) -> [UInt8] {
            let bytes = Array(text.utf8.prefix(length))
            return bytes + [UInt8](repeating: 0, count: length - bytes.count)
        }
        func octal(_ value: Int, _ length: Int) -> [UInt8] {
            let digits = String(value, radix: 8)
            return field(String(repeating: "0", count: length - 1 - digits.count) + digits, length)
        }
        for entry in entries {
            let body: [UInt8] = entry.link == nil && !entry.folder && entry.kind == nil ? Array(entry.text.utf8) : []
            let type: UInt8 = entry.kind?.asciiValue ?? (entry.link != nil ? 0x32 : entry.folder ? 0x35 : 0x30)
            var header: [UInt8] = field(entry.name, 100)
            header += octal(entry.mode ?? (entry.folder ? 0o755 : 0o644), 8)
            header += octal(0, 8)
            header += octal(0, 8)
            header += octal(body.count, 12)
            header += octal(0, 12)
            header += [UInt8](repeating: 0x20, count: 8)
            header.append(type)
            header += field(entry.link ?? "", 100)
            header += field("ustar", 6)
            header += Array("00".utf8)
            header += [UInt8](repeating: 0, count: 64)
            // A device's numbers: /dev/null's (1, 3).
            header += entry.kind == "3" ? octal(1, 8) + octal(3, 8) : [UInt8](repeating: 0, count: 16)
            header += [UInt8](repeating: 0, count: 512 - header.count)
            let sum = header.reduce(0) { $0 + Int($1) }
            let digits = String(sum, radix: 8)
            let checksum: [UInt8] = Array((String(repeating: "0", count: 6 - digits.count) + digits).utf8) + [0, 0x20]
            header.replaceSubrange(148..<156, with: checksum)
            tar.append(contentsOf: header)
            tar.append(contentsOf: body)
            tar.append(Data(count: (512 - body.count % 512) % 512))
        }
        tar.append(Data(count: 1024))
        let scratch = root.appendingPathComponent("scratch-" + UUID().uuidString + ".tar")
        try tar.write(to: scratch)
        let gzip = ToolPath.resolve("gzip") ?? "/usr/bin/gzip"
        let zipped = await Command.output(gzip, ["-n", "-f", scratch.path], errors: true)
        #expect(zipped?.status == 0, Comment(rawValue: zipped?.text ?? "gzip could not be started"))
        let file = URL(fileURLWithPath: scratch.path + ".gz")
        defer { try? FileManager.default.removeItem(at: file) }
        return try Data(contentsOf: file)
    }

    /// `entries` packed as the folder `target` (each name under its name,
    /// an absolute one as it is) and unpacked as that folder alone where it
    /// goes, as the conversation's folder or the memory is: what went wrong.
    private func unpack(_ entries: [Entry], into target: URL) async throws -> String? {
        let name = target.lastPathComponent
        let named = entries.map { entry in
            var entry = entry
            if !entry.name.hasPrefix("/") { entry.name = name + "/" + entry.name }
            // A hard link names the file it links to as the archive does.
            if entry.kind == "1", let link = entry.link, !link.hasPrefix("/"), !link.hasPrefix("..") { entry.link = name + "/" + link }
            return entry
        }
        let archive = root.appendingPathComponent("archive-" + UUID().uuidString + ".tgz")
        try await tarball(named).write(to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }
        return await VisorServer.unpack(archive, into: target.deletingLastPathComponent(), only: name)
    }

    // MARK: Ids

    @Test func testAHostileFileIdIsRefusedByWriteAndNothingIsWritten() async throws {
        // Even an id the offer names (as a hostile offer past the plan
        // would) is taken only as a plain name.
        let place = "projects/{project}/\(conversation).jsonl"
        let folder = try move(offer(files: (hostileIDs + ["conversation-0"]).map { MigrationFile(id: $0, place: place, size: 4, packed: false) }))
        let before = everything()
        for id in hostileIDs {
            let written = write(id, Data("evil".utf8))
            #expect(written.type == "error", "write took \(id.prefix(40))")
        }
        #expect(everything() == before, "nothing made, nothing removed (`..` once removed the migrations folder)")
        #expect(FileManager.default.fileExists(atPath: folder.path))
        try outsideIsAsItWas()
        // A plain id still writes, in the move's own folder.
        #expect(write("conversation-0", Data("fine".utf8)).offset == 4)
        #expect((try String(contentsOf: folder.appendingPathComponent("conversation-0"), encoding: .utf8)) == "fine")
    }

    @Test func testAPlanRefusesAnOfferWithAHostileIdResumeIdFolderOrPlace() async throws {
        let place = "projects/{project}/\(conversation).jsonl"
        for id in hostileIDs {
            let refused = await plan(offer(files: [MigrationFile(id: id, place: place, size: 1, packed: false)]))
            #expect(refused.plan == nil && refused.message?.contains("was refused") == true, Comment(rawValue: refused.message ?? "planned \(id)"))
        }
        let twice = await plan(offer(files: [MigrationFile(id: "conversation-0", place: place, size: 1, packed: false),
                                             MigrationFile(id: "conversation-0", place: "", size: 1, packed: true)]))
        #expect(twice.plan == nil, "an id twice")
        for resume in ["../x", "-x", "a b; rm -rf ~", "", "/etc/passwd", String(repeating: "a", count: 300)] {
            let refused = await plan(offer(resume: resume))
            #expect(refused.plan == nil, "resume id \(resume.prefix(40))")
        }
        for cwd in ["relative/app", "/Users/a/../../etc", "/a//b", "/a/./b", ""] {
            let refused = await plan(offer(cwd: cwd))
            #expect(refused.plan == nil, "cwd \(cwd)")
        }
        for hostile in ["settings.json", ".credentials.json", "projects/{project}/../../settings.json", "/etc/passwd", "../x",
                        "projects/{project}/other.jsonl", "projects/elsewhere/\(conversation).jsonl", "projects/{project}/.\(conversation)",
                        "projects/{project}/\(conversation).jsonl/../../../x", "projects/{project}/\(conversation)/x", "projects/{project}"] {
            let refused = await plan(offer(files: [MigrationFile(id: "conversation-0", place: hostile, size: 1, packed: false)]))
            #expect(refused.plan == nil && refused.message?.contains("is not where the agent keeps") == true,
                    Comment(rawValue: refused.message ?? "planned \(hostile)"))
        }
        // An honest offer still plans.
        let honest = await plan(offer(files: [MigrationFile(id: "conversation-0", place: place, size: 1, packed: false),
                                              MigrationFile(id: "conversation-1", place: "projects/{project}/\(conversation)", size: 1, packed: true),
                                              MigrationFile(id: "memory", place: "", size: 1, packed: true)]))
        #expect(honest.plan != nil, Comment(rawValue: honest.message ?? ""))
        // The agent's settings are never written (the server's own are its).
        let config = ClaudeSessionFiles.configDirectory(home: home).path
        let stray = everything().filter { $0.hasSuffix("/x") || ($0.hasSuffix("settings.json") && $0 != VisorServer.settingsURL.path) || $0.hasPrefix(config + "/") }
        #expect(stray.isEmpty, "\(stray)")
        try outsideIsAsItWas()
    }

    @Test func testEachAgentsPlaceIsOnlyWhereItKeepsTheConversation() {
        let cwd = "/Users/a/app"
        #expect(SessionCatalog.destination(of: "projects/{project}/\(conversation).jsonl", agent: .claude, cwd: cwd, resume: conversation) != nil)
        #expect(SessionCatalog.destination(of: "projects/{project}/\(conversation)", agent: .claude, cwd: cwd, resume: conversation) != nil)
        #expect(SessionCatalog.destination(of: "settings.json", agent: .claude, cwd: cwd, resume: conversation) == nil)
        #expect(SessionCatalog.destination(of: "projects/{project}/\(conversation).jsonl", agent: .claude, cwd: cwd, resume: "other") == nil)
        #expect(SessionCatalog.destination(of: "sessions/2026/11/16/rollout-2026-11-16T10-00-00-\(conversation).jsonl", agent: .codex, cwd: cwd,
                                           resume: conversation) != nil)
        #expect(SessionCatalog.destination(of: "config.toml", agent: .codex, cwd: cwd, resume: conversation) == nil)
        #expect(SessionCatalog.destination(of: "sessions/../auth-\(conversation).jsonl", agent: .codex, cwd: cwd, resume: conversation) == nil)
        #expect(SessionCatalog.destination(of: "sessions/\(conversation).json", agent: .openrouter, cwd: cwd, resume: conversation) != nil)
        #expect(SessionCatalog.destination(of: "config.json", agent: .openrouter, cwd: cwd, resume: conversation) == nil)
    }

    @Test func testTheFinishRefusesAHostilePlaceEvenPastThePlan() async throws {
        let config = ClaudeSessionFiles.configDirectory(home: home)
        let cwd = home.appendingPathComponent("Developer/app").path
        for (id, place) in [("conversation-0", "settings.json"), ("conversation-0", "projects/{project}/../../settings.json"), ("../conversation-0", "projects/{project}/\(conversation).jsonl")] {
            let folder = try move(offer(cwd: cwd, files: [MigrationFile(id: id, place: place, size: 4, packed: false)]))
            try Data("evil".utf8).write(to: folder.appendingPathComponent("conversation-0"))
            var finishing = Envelope(type: "migration")
            finishing.migration = "p"
            let finished = await server.migrationFinish(finishing)
            #expect(finished.type == "error", "finished with \(id) at \(place)")
            #expect(!FileManager.default.fileExists(atPath: config.appendingPathComponent("settings.json").path))
            #expect(!FileManager.default.fileExists(atPath: cwd), "nothing made")
            #expect(server.sessions.isEmpty)
        }
        try outsideIsAsItWas()
    }

    // MARK: Archives

    @Test func testAHostileArchiveIsRefusedAndNothingIsWrittenOutside() async throws {
        let target = home.appendingPathComponent("Developer/copied", isDirectory: true)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let hostile: [(String, [Entry])] = [
            ("../evil", [Entry(name: "ok.txt", text: "fine"), Entry(name: "../evil", text: "evil")]),
            ("deep ../", [Entry(name: "a/../../../../outside/evil", text: "evil")]),
            ("absolute", [Entry(name: outside.appendingPathComponent("evil").path, text: "evil")]),
            ("absolute link", [Entry(name: "link", link: outside.path), Entry(name: "link/evil", text: "evil")]),
            ("link up", [Entry(name: "up", link: "../../../outside")]),
            ("link out, through a link to itself", [Entry(name: "here", link: "."), Entry(name: "out", link: "here/../outside")]),
            ("link out of the folder, to what is beside it", [Entry(name: "beside", link: "../\(conversation).jsonl")]),
        ]
        for (what, entries) in hostile {
            let before = everything()
            let unpacked = try await unpack(entries, into: target)
            #expect(unpacked != nil, "\(what) unpacked")
            #expect(!FileManager.default.fileExists(atPath: target.path), "\(what): nothing put in its place")
            let made = everything().subtracting(before)
            #expect(made.isEmpty, "\(what) made \(made)")
            try outsideIsAsItWas()
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("evil").path))
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("evil").path))
        }
    }

    @Test func testAnArchivesOwnLinksThatStayInsideItStillCome() async throws {
        let target = home.appendingPathComponent("Developer/copied", isDirectory: true)
        let unpacked = try await unpack([
            Entry(name: "README.md", text: "read me"),
            Entry(name: "docs", folder: true),
            Entry(name: "docs/readme", link: "../README.md"),
        ], into: target)
        #expect(unpacked == nil, Comment(rawValue: unpacked ?? ""))
        #expect((try String(contentsOf: target.appendingPathComponent("docs/readme"), encoding: .utf8)) == "read me")
        #expect((try FileManager.default.destinationOfSymbolicLink(atPath: target.appendingPathComponent("docs/readme").path)) == "../README.md")
        #expect((try FileManager.default.contentsOfDirectory(atPath: target.path)).sorted() == ["README.md", "docs"])
        #expect((try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)) == ["copied"], "no folder of the unpacking's left")
    }

    @Test func testAConversationsFolderOrMemoryHoldsThatFolderAlone() async throws {
        let project = home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("memory.tgz")
        try await tarball([Entry(name: "memory/MEMORY.md", text: "index"), Entry(name: "\(conversation).jsonl", text: "over another")]).write(to: archive)
        #expect(await VisorServer.unpack(archive, into: project, only: "memory") != nil, "a file beside it")
        try await tarball([Entry(name: "memory/../\(conversation).jsonl", text: "evil")]).write(to: archive)
        #expect(await VisorServer.unpack(archive, into: project, only: "memory") != nil, "through ..")
        #expect((try FileManager.default.contentsOfDirectory(atPath: project.path)).isEmpty)
        // The folder itself a link, or a file: refused.
        try await tarball([Entry(name: "memory", link: "../outside")]).write(to: archive)
        #expect(await VisorServer.unpack(archive, into: project, only: "memory") != nil, "a link")
        try await tarball([Entry(name: "memory", text: "a file")]).write(to: archive)
        #expect(await VisorServer.unpack(archive, into: project, only: "memory") != nil, "a file")
        #expect((try FileManager.default.contentsOfDirectory(atPath: project.path)).isEmpty)
        try await tarball([Entry(name: "memory/MEMORY.md", text: "index")]).write(to: archive)
        #expect(await VisorServer.unpack(archive, into: project, only: "memory") == nil)
        #expect((try String(contentsOf: project.appendingPathComponent("memory/MEMORY.md"), encoding: .utf8)) == "index")
    }

    // MARK: Walking what was unpacked

    /// A folder of the test's own, to walk.
    private func tree(_ name: String) throws -> URL {
        let made = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        return made
    }

    private func run(_ tool: String, _ arguments: [String]) async -> (status: Int32, text: String) {
        await Command.output(ToolPath.resolve(tool) ?? "/usr/bin/" + tool, arguments, errors: true) ?? (-1, "\(tool) could not be started")
    }

    private func links(_ url: URL) -> Int? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.referenceCount] as? NSNumber)?.intValue
    }

    @Test func testAHardLinkInsideComesAndOneToAFileOutsideIsRefused() async throws {
        // Inside: both names come, the same file.
        let target = home.appendingPathComponent("Developer/copied", isDirectory: true)
        let inside = try await unpack([Entry(name: "a.txt", text: "same"), Entry(name: "b.txt", link: "a.txt", kind: "1")], into: target)
        #expect(inside == nil, Comment(rawValue: inside ?? ""))
        #expect((try String(contentsOf: target.appendingPathComponent("b.txt"), encoding: .utf8)) == "same")
        #expect(links(target.appendingPathComponent("a.txt")) == 2)
        try FileManager.default.removeItem(at: target)
        // Outside: tar may refuse to make it, or the walk refuses what it made.
        let sentinel = outside.appendingPathComponent("sentinel")
        for link in [sentinel.path, "../../outside/sentinel", "../../../outside/sentinel"] {
            let unpacked = try await unpack([Entry(name: "evil", link: link, kind: "1")], into: target)
            #expect(unpacked != nil, "a hard link to \(link) unpacked")
            #expect(!FileManager.default.fileExists(atPath: target.path))
            #expect(links(sentinel) == 1, "nothing left linked to the file outside")
        }
        try outsideIsAsItWas()
        // The walk itself: a tree holding a second name for a file outside it.
        let walked = try tree("walked")
        try FileManager.default.linkItem(at: sentinel, to: walked.appendingPathComponent("x"))
        #expect(VisorServer.unsafeTree(walked)?.contains("hard link") == true)
        try FileManager.default.removeItem(at: walked)
        let both = try tree("both")
        try Data("a".utf8).write(to: both.appendingPathComponent("a"))
        try FileManager.default.linkItem(at: both.appendingPathComponent("a"), to: both.appendingPathComponent("b"))
        #expect(VisorServer.unsafeTree(both) == nil, "both names inside")
    }

    /// A folder an archive leaves unreadable (0000) or passable but not
    /// listable (0111) once was taken as empty, so a link out inside it
    /// came across (and 0111 can be walked through).
    @Test func testAnUnreadableFolderIsWalkedAndItsLinkOutRefused() async throws {
        let target = home.appendingPathComponent("Developer/copied", isDirectory: true)
        for mode in [0o000, 0o111] {
            let unpacked = try await unpack([Entry(name: "locked", folder: true, mode: mode), Entry(name: "locked/x", link: "../../../../outside")],
                                            into: target)
            #expect(unpacked != nil, "a folder of mode \(String(mode, radix: 8)) unpacked")
            #expect(!FileManager.default.fileExists(atPath: target.path), "nothing put in its place")
            #expect((try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)).isEmpty, "the unpacking's folder gone again")
            try outsideIsAsItWas()

            // The walk itself, on a folder made so here.
            let walked = try tree("walked-\(mode)")
            let locked = walked.appendingPathComponent("locked", isDirectory: true)
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: locked.appendingPathComponent("x").path, withDestinationPath: "../../outside")
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: locked.path)
            #expect(VisorServer.unsafeTree(walked)?.contains("leads out") == true, "mode \(String(mode, radix: 8))")
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: locked.path)
            VisorServer.removeTree(walked)
            #expect(!FileManager.default.fileExists(atPath: walked.path), "removed, unreadable folder and all")
        }
        // One that is only read-only still comes, opened to its owner.
        let unpacked = try await unpack([Entry(name: "kept", folder: true, mode: 0o555), Entry(name: "kept/a.txt", text: "fine")], into: target)
        #expect(unpacked == nil, Comment(rawValue: unpacked ?? ""))
        #expect((try String(contentsOf: target.appendingPathComponent("kept/a.txt"), encoding: .utf8)) == "fine")
    }

    @Test func testADeviceOrAFifoIsRefused() async throws {
        let target = home.appendingPathComponent("Developer/copied", isDirectory: true)
        // Unpacked: tar makes a fifo; a device it makes only as root, and
        // fails otherwise. Refused either way.
        for (what, entry) in [("a fifo", Entry(name: "pipe", kind: "6")), ("a device", Entry(name: "null", kind: "3"))] {
            let unpacked = try await unpack([Entry(name: "ok.txt", text: "fine"), entry], into: target)
            #expect(unpacked != nil, "\(what) unpacked")
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
        // The walk itself.
        let fifo = try tree("fifo")
        let made = await run("mkfifo", [fifo.appendingPathComponent("pipe").path])
        #expect(made.status == 0, Comment(rawValue: made.text))
        #expect(VisorServer.unsafeTree(fifo)?.contains("not a file, a folder or a link") == true)
        // A device needs mknod's privilege (root, or CAP_MKNOD in a
        // container): where it is refused, only the unpacking above is tried.
        let device = try tree("device")
        let node = await run("mknod", [device.appendingPathComponent("null").path, "c", "1", "3"])
        if node.status == 0 {
            #expect(VisorServer.unsafeTree(device)?.contains("not a file, a folder or a link") == true)
        } else {
            print("MigrationContainmentTests: the device walk skipped, mknod refused here: \(node.text)")
        }
    }

    // MARK: A conversation's id

    @Test func testAConversationsIDIsAUUIDAndNeverTheMemoryOrAnotherFile() async throws {
        #expect(SessionCatalog.isConversationID(conversation))
        #expect(SessionCatalog.isConversationID("01A10547-9FEA-7C53-A28C-407A4862AD19"))
        for resume in ["memory", "rollout", "a", "11111111-2222-3333-4444-55555555555", "11111111-2222-3333-4444-5555555555555",
                       "11111111_2222-3333-4444-555555555555", "g1111111-2222-3333-4444-555555555555", "111111112222-3333-4444-555555555555-"] {
            #expect(!SessionCatalog.isConversationID(resume), "\(resume)")
            #expect(VisorServer.unsafeOffer(offer(resume: resume)) != nil, "\(resume)")
        }
        let cwd = home.appendingPathComponent("Developer/app").path
        #expect(SessionCatalog.destination(of: "projects/{project}/memory", agent: .claude, cwd: cwd, resume: "memory") == nil)
        for resume in ["rollout", "a", "-"] {
            #expect(SessionCatalog.destination(of: "sessions/2026/11/16/rollout-2026-11-16T10-00-00-\(conversation).jsonl", agent: .codex, cwd: cwd,
                                               resume: resume) == nil, "\(resume)")
        }
        // Past the plan, the finish holds it too: the project's memory is
        // left as it was, and nothing starts.
        let memory = ClaudeSessionFiles.projectsRoot(home: home)
            .appendingPathComponent(ClaudeSessionFiles.projectDirectoryName(for: cwd), isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: memory.appendingPathComponent("MEMORY.md"))
        let archive = try await tarball([Entry(name: "memory/MEMORY.md", text: "theirs")])
        let folder = try move(offer(resume: "memory", cwd: cwd,
                                    files: [MigrationFile(id: "conversation-1", place: "projects/{project}/memory", size: archive.count, packed: true)]))
        try archive.write(to: folder.appendingPathComponent("conversation-1"))
        var finishing = Envelope(type: "migration")
        finishing.migration = "p"
        let finished = await server.migrationFinish(finishing)
        #expect(finished.type == "error")
        #expect((try String(contentsOf: memory.appendingPathComponent("MEMORY.md"), encoding: .utf8)) == "mine")
        #expect(server.sessions.isEmpty)
        // And unpacking as `memory` never takes the place of one there.
        let carried = root.appendingPathComponent("memory.tgz")
        try archive.write(to: carried)
        #expect(await VisorServer.unpack(carried, into: memory.deletingLastPathComponent(), only: "memory") != nil)
        #expect((try String(contentsOf: memory.appendingPathComponent("MEMORY.md"), encoding: .utf8)) == "mine")
    }

    /// The conversation's file put where the agent keeps it.
    private func finish(carrying text: String, folder files: [Entry]? = nil, cwd: String) async throws -> Envelope {
        var offered = [MigrationFile(id: "conversation-0", place: "projects/{project}/\(conversation).jsonl", size: text.utf8.count, packed: false)]
        var archive: Data?
        if let files {
            let made = try await tarball(files)
            offered.insert(MigrationFile(id: "conversation-1", place: "projects/{project}/\(conversation)", size: made.count, packed: true), at: 0)
            archive = made
        }
        let folder = try move(offer(cwd: cwd, files: offered))
        try Data(text.utf8).write(to: folder.appendingPathComponent("conversation-0"))
        try archive?.write(to: folder.appendingPathComponent("conversation-1"))
        var finishing = Envelope(type: "migration")
        finishing.migration = "p"
        return await server.migrationFinish(finishing)
    }

    @Test func testAnotherConversationHereIsNeverWrittenOverAndTheSameOneComeBackIs() async throws {
        let cwd = home.appendingPathComponent("Developer/app").path
        let project = ClaudeSessionFiles.projectsRoot(home: home)
            .appendingPathComponent(ClaudeSessionFiles.projectDirectoryName(for: cwd), isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(conversation), withIntermediateDirectories: true)
        let mine = project.appendingPathComponent(conversation + ".jsonl")
        try Data("mine\n".utf8).write(to: mine)
        try Data("old".utf8).write(to: project.appendingPathComponent("\(conversation)/agent-1.jsonl"))

        // Another conversation under the same id (a move naming an id here):
        // refused, nothing touched, nothing started.
        for text in ["theirs\n", "min", "mine\n".uppercased()] {
            let refused = try await finish(carrying: text, folder: [Entry(name: "\(conversation)/agent-1.jsonl", text: "theirs")], cwd: cwd)
            #expect(refused.type == "error", "\(text) written over mine")
            #expect(refused.message?.contains("is here already") == true, Comment(rawValue: refused.message ?? ""))
            #expect((try String(contentsOf: mine, encoding: .utf8)) == "mine\n")
            #expect((try String(contentsOf: project.appendingPathComponent("\(conversation)/agent-1.jsonl"), encoding: .utf8)) == "old")
            #expect((try FileManager.default.contentsOfDirectory(atPath: project.path)).sorted() == [conversation, conversation + ".jsonl"])
            #expect(server.sessions.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: cwd), "nothing made")
        }

        // The same conversation come back further along: its log replaced
        // (nothing in it lost), its folder set aside, never removed.
        let back = try await finish(carrying: "mine\nmore\n", folder: [Entry(name: "\(conversation)/agent-1.jsonl", text: "new")], cwd: cwd)
        #expect(back.type != "error", Comment(rawValue: back.message ?? ""))
        #expect((try String(contentsOf: mine, encoding: .utf8)) == "mine\nmore\n")
        #expect((try String(contentsOf: project.appendingPathComponent("\(conversation)/agent-1.jsonl"), encoding: .utf8)) == "new")
        let aside = try #require(try FileManager.default.contentsOfDirectory(atPath: project.path).first { $0.hasPrefix(conversation + ".before-move-") })
        #expect((try String(contentsOf: project.appendingPathComponent("\(aside)/agent-1.jsonl"), encoding: .utf8)) == "old")
        #expect(server.sessions.count == 1)
    }

    @Test func testCodexsRolloutIsMatchedExactly() throws {
        let name = "rollout-2026-11-16T10-00-00-\(conversation).jsonl"
        #expect(SessionCatalog.isCodexRollout(name, id: conversation))
        for wrong in ["rollout-2026-11-16T10-00-00-\(conversation)x.jsonl", "rollout-\(conversation).jsonl", "x-2026-11-16T10-00-00-\(conversation).jsonl",
                      "rollout-2026-11-16T10-00-0a-\(conversation).jsonl", "rollout-2026-11-16T10-00-00-\(conversation).json",
                      "rollout-2026-11-16T10-00-00-x\(conversation).jsonl", "rollout-2026-11-16 10-00-00-\(conversation).jsonl"] {
            #expect(!SessionCatalog.isCodexRollout(wrong, id: conversation), "\(wrong)")
        }
        for id in ["a", "rollout", "00", "", "jsonl"] { #expect(!SessionCatalog.isCodexRollout(name, id: id), "\(id)") }
        let cwd = "/Users/a/app"
        #expect(SessionCatalog.destination(of: "sessions/2026/11/16/\(name)", agent: .codex, cwd: cwd, resume: conversation) != nil)
        for place in ["sessions/\(name)", "sessions/2026/11/\(name)", "sessions/2026/11/16/x/\(name)", "sessions/26/11/16/\(name)",
                      "sessions/2026/11/16/rollout-2026-11-16T10-00-00-\(conversation)-\(conversation).jsonl", "archived_sessions/2026/11/16/\(name)"] {
            #expect(SessionCatalog.destination(of: place, agent: .codex, cwd: cwd, resume: conversation) == nil, "\(place)")
        }
        // Found here by its id exactly, never by a part of it.
        let codex = root.appendingPathComponent("codex", isDirectory: true)
        let day = codex.appendingPathComponent("sessions/2026/11/16", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try Data().write(to: day.appendingPathComponent(name))
        try Data().write(to: day.appendingPathComponent("rollout-2026-11-16T09-00-00-aaaaaaaa-2222-3333-4444-555555555555.jsonl"))
        #expect((SessionCatalog.codexRollout(id: conversation, in: codex)?.lastPathComponent) == name)
        for id in ["a", "rollout", "2026", "5555"] { #expect(SessionCatalog.codexRollout(id: id, in: codex) == nil, "\(id)") }
    }

    // MARK: How much an archive unpacks to

    /// GNU tar's listing (Linux's) and bsdtar's (the Mac's, Windows's):
    /// names with spaces, numbers, dates and arrows in them, a link, a hard
    /// link, a device; anything else not read at all.
    @Test func testBothTarsListingsSizesAreRead() {
        let gnu = """
            drwxr-xr-x 501/20            0 2026-11-16 10:00 memory/
            -rw-r--r-- 501/20         1234 2026-11-16 10:00 memory/a file 99999 2026-11-16 10:00.txt
            lrwxrwxrwx 501/20            0 2026-11-16 10:00 memory/l 777 -> 888 -> target
            hrw-r--r-- 501/20            0 2026-11-16 10:00 memory/h link to memory/a file 99999 2026-11-16 10:00.txt
            -rw-r--r-- 0/0          100000 1970-01-01 00:00 memory/big
            crw-r--r-- 0/0             1,3 1970-01-01 00:00 memory/null

            """
        #expect(VisorServer.listedBytes(gnu).map { [$0.entries, $0.bytes] } == [6, 101_234])
        let bsd = """
            drw-r--r--  0 501    20          0 Dec 31  1969 memory/
            -rw-r--r--  0 501    20       1234 Dec 31  1969 memory/a file 99999 Nov 16 10:00.txt
            lrw-r--r--  0 501    20          0 Nov 16 10:00 memory/l 777 -> 888 -> target
            hrw-r--r--  0 501    20          0 Nov 16 10:00 memory/h link to memory/a file 99999 Nov 16 10:00.txt
            -rw-r--r--  0 501    20     100000 Dec 31  1969 memory/big
            crw-r--r--  0 0      0         1,3 Dec 31  1969 memory/null
            """
        #expect(VisorServer.listedBytes(bsd).map { [$0.entries, $0.bytes] } == [6, 101_234])
        #expect(VisorServer.listedBytes("").map { [$0.entries, $0.bytes] } == [0, 0])
        for line in ["memory/a", "-rw-r--r-- 501/20 12 memory", "-rw-r--r-- 501/20 x 2026-11-16 10:00 memory/a",
                     "-rw-r--r-- 501/20 -5 2026-11-16 10:00 memory/a", "-rw-r--r-- 501/20 99999999999999999999 2026-11-16 10:00 memory/a",
                     "-rw-r--r--  0 a b c  g 1 2       1234 Dec 31  1969 memory/a", "-rw-r--r--  0 501 20 x Dec 31  1969 memory/a"] {
            #expect(VisorServer.listedBytes(line) == nil, "\(line)")
        }
        let past = "-rw-r--r-- 0/0 \(Int.max) 2026-11-16 10:00 memory/a\n-rw-r--r-- 0/0 1 2026-11-16 10:00 memory/b"
        #expect(VisorServer.listedBytes(past) == nil, "past counting")
    }

    /// The tar here (GNU's on Linux, bsdtar on a Mac) lists what is read.
    @Test func testThisTarsListingIsRead() async throws {
        let archive = root.appendingPathComponent("listed.tgz")
        try await tarball([Entry(name: "memory", folder: true), Entry(name: "memory/a file 12 34.txt", text: String(repeating: "x", count: 1234)),
                           Entry(name: "memory/l -> 5", link: "a file 12 34.txt"), Entry(name: "memory/h", link: "memory/a file 12 34.txt", kind: "1"),
                           Entry(name: "memory/b", text: String(repeating: "y", count: 100))]).write(to: archive)
        let listed = await run("tar", ["-t", "-v", "-P", "-z", "--numeric-owner", "-f", archive.path])
        #expect(listed.status == 0, Comment(rawValue: listed.text))
        #expect(VisorServer.listedBytes(listed.text).map { [$0.entries, $0.bytes] } == [5, 1334], Comment(rawValue: listed.text))
    }

    /// 256 KB of one character, which gzip makes a few hundred bytes of.
    private func compressible(into target: URL) async throws -> URL {
        let archive = root.appendingPathComponent("zeros-" + UUID().uuidString + ".tgz")
        let data = try await tarball([Entry(name: target.lastPathComponent + "/zeros", text: String(repeating: "0", count: 256 << 10))])
        #expect(data.count < 4 << 10, "\(data.count) bytes")
        try data.write(to: archive)
        return archive
    }

    @Test func testASmallArchiveThatUnpacksPastALimitIsRefusedBeforeItIsUnpacked() async throws {
        let target = home.appendingPathComponent("Developer/copied", isDirectory: true)
        let archive = try await compressible(into: target)
        let before = everything()
        let limits: [(VisorServer.UnpackLimits, String)] = [
            (VisorServer.UnpackLimits(fileCap: 64 << 10), "a move carries at most 64 KB of a file"),
            (VisorServer.UnpackLimits(budget: 64 << 10), "64 KB is left once its other files are counted"),
            (VisorServer.UnpackLimits(budget: -5), "nothing is left once its other files are counted"),
            (VisorServer.UnpackLimits(free: 300 << 10, margin: 100 << 10), "has 300 KB free, which must keep 100 KB to spare"),
        ]
        for (limit, says) in limits {
            let refused = await VisorServer.unpack(archive, into: target.deletingLastPathComponent(), only: target.lastPathComponent, limits: limit)
            #expect(refused?.hasPrefix("it unpacks to 256 KB, and ") == true, Comment(rawValue: refused ?? "unpacked"))
            #expect(refused?.contains(says) == true, Comment(rawValue: refused ?? "unpacked"))
            // Nothing made, not even the folder it would have unpacked into.
            #expect(everything() == before)
        }
        // Under every limit, it comes.
        let unpacked = await VisorServer.unpack(archive, into: target.deletingLastPathComponent(), only: target.lastPathComponent,
                                                limits: VisorServer.UnpackLimits(fileCap: 256 << 10, budget: 256 << 10, free: 1 << 20, margin: 768 << 10))
        #expect(unpacked == nil, Comment(rawValue: unpacked ?? ""))
        #expect(VisorServer.fileSize(target.appendingPathComponent("zeros")) == 256 << 10)
        #expect(VisorServer.unpackedBytes(target) == 256 << 10)
        #expect((try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)) == ["copied"], "no folder of the unpacking's left")
    }

    /// The listing is the archive's word: a tar that writes more than it
    /// declared (a stand-in, as no honest archive does) is stopped while it
    /// writes, well before it is done.
    @Test func testAnUnpackingThatRunsPastWhatItDeclaredIsStopped() async throws {
        let fake = root.appendingPathComponent("fake-tar")
        // Asked to unpack into `-C <folder>` (its last argument), it writes
        // 64 KB at a time, up to 128 MB, then waits.
        try Data("""
            #!/bin/sh
            for last; do :; done
            mkdir -p "$last/copied"
            i=0
            while [ $i -lt 2048 ]; do head -c 65536 /dev/zero >> "$last/copied/big"; i=$((i + 1)); done
            exec sleep 30

            """.utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: fake.path)
        let started = ContinuousClock.now
        for (limits, says) in [(VisorServer.UnpackLimits(), "more than the 4 KB its listing declared"),
                               (VisorServer.UnpackLimits(fileCap: 2 << 20, slack: 64 << 20), "more than the 2.0 MB a move carries of a file"),
                               (VisorServer.UnpackLimits(budget: 3 << 20, slack: 64 << 20), "more than the 3.0 MB left of what a move carries in all"),
                               (VisorServer.UnpackLimits(free: 6 << 20, margin: 1 << 20, slack: 64 << 20), "has free with 1.0 MB to spare")] {
            let staging = try tree("staging-" + UUID().uuidString)
            let bound = VisorServer.unpackBound(4 << 10, limits, in: staging)
            let stopped = await VisorServer.extract(root.appendingPathComponent("none.tgz"), into: staging, tar: fake.path, bound: bound,
                                                    every: .milliseconds(50))
            #expect(stopped?.contains(says) == true, Comment(rawValue: stopped ?? "not stopped"))
            #expect(stopped?.hasSuffix("and was stopped") == true, Comment(rawValue: stopped ?? "not stopped"))
            #expect(VisorServer.unpackedBytes(staging) < 128 << 20, "stopped before it was done")
            VisorServer.removeTree(staging)
        }
        #expect(ContinuousClock.now - started < .seconds(30), "never waited for it to end of itself")
    }

    /// What a move's (or a restore's) archive may unpack to: what is left
    /// of the total once its other files are counted, each as carried or as
    /// it unpacked to, and the room where it unpacks.
    @Test func testAnArchivesLimitsCountTheMovesOtherFiles() {
        let files = [MigrationFile(id: "conversation-0", place: "projects/{project}/\(conversation).jsonl", size: 1 << 30, packed: false),
                     MigrationFile(id: "conversation-1", place: "projects/{project}/\(conversation)", size: 100 << 20, packed: true),
                     MigrationFile(id: "memory", place: "", size: 1 << 20, packed: true)]
        server.freeBytes = { url in url.path == "/there" ? 5 << 30 : nil }
        let folder = server.unpackLimits(files[1], of: files, landed: [:], in: URL(fileURLWithPath: "/there"))
        #expect(folder.fileCap == VisorServer.migrationFileCap)
        #expect(folder.budget == VisorServer.migrationTotalCap - (1 << 30) - (1 << 20))
        #expect(folder.free == 5 << 30)
        #expect(folder.margin == VisorServer.migrationFreeMargin)
        // The memory after the folder: the folder as it unpacked.
        let memory = server.unpackLimits(files[2], of: files, landed: ["conversation-1": 900 << 20], in: URL(fileURLWithPath: "/elsewhere"))
        #expect(memory.budget == VisorServer.migrationTotalCap - (1 << 30) - (900 << 20))
        #expect(memory.free == nil)
    }

    // MARK: Backups

    /// A backup written by hand, as a hostile server would make one, or one
    /// changed where it lies: its backup.json for the session `S`, and that
    /// session's offer and files.
    private func backup(_ offer: MigrationOffer, files: [String: Data] = [:], projects: JSONValue? = nil) throws -> URL {
        let folder = root.appendingPathComponent("backup-" + UUID().uuidString, isDirectory: true)
        let kept = folder.appendingPathComponent("S", isDirectory: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        let made = SessionBackup(path: folder.path, created: 0, from: "Elsewhere",
                                 sessions: [SessionBackupItem(id: "S", title: "Moving", outcome: "Backed up.", kept: true)], size: 0)
        try VisorServer.write(made.json, to: folder.appendingPathComponent("backup.json"))
        // A backup from before 0.61 lists the session's projects too.
        var json = offer.json
        if let projects, case .object(var fields) = json {
            fields["projects"] = projects
            json = .object(fields)
        }
        try VisorServer.write(json, to: kept.appendingPathComponent("offer.json"))
        for (name, data) in files { try data.write(to: kept.appendingPathComponent(name)) }
        return folder
    }

    private func restored(_ folder: URL) async -> String {
        let restored = await server.restore(from: folder, only: nil)
        return restored.backup?.sessions.first?.outcome ?? restored.message ?? ""
    }

    @Test func testAHostileBackupIsNotRestored() async throws {
        let cwd = home.appendingPathComponent("Developer/app")
        let memory = ClaudeSessionFiles.projectsRoot(home: home)
            .appendingPathComponent(ClaudeSessionFiles.projectDirectoryName(for: cwd.path), isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: memory.appendingPathComponent("MEMORY.md"))
        let memoryArchive = try await tarball([Entry(name: "memory/MEMORY.md", text: "theirs")])

        // Its conversation's id the project's memory.
        let asMemory = await restored(try backup(offer(resume: "memory", cwd: cwd.path,
                                                       files: [MigrationFile(id: "conversation-1", place: "projects/{project}/memory",
                                                                             size: memoryArchive.count, packed: true)]),
                                                 files: ["conversation-1.tgz": memoryArchive]))
        #expect(asMemory.hasPrefix("Not restored: its conversation's id"), Comment(rawValue: asMemory))
        #expect((try String(contentsOf: memory.appendingPathComponent("MEMORY.md"), encoding: .utf8)) == "mine")

        // Another session's files under this one's name.
        var other = offer(cwd: cwd.path)
        other.session.id = "T"
        let elsewhere = await restored(try backup(other))
        #expect(elsewhere.hasPrefix("Not restored: its files are of another session"), Comment(rawValue: elsewhere))

        // The conversation's folder linking out of itself.
        let linkOut = try await tarball([Entry(name: "\(conversation)/up", link: "../../../outside")])
        let linked = await restored(try backup(offer(cwd: cwd.path, files: [MigrationFile(id: "conversation-1", place: "projects/{project}/\(conversation)",
                                                                                      size: linkOut.count, packed: true)]),
                                               files: ["conversation-1.tgz": linkOut]))
        #expect(linked.hasPrefix("Not restored: could not unpack"), Comment(rawValue: linked))
        #expect(!FileManager.default.fileExists(atPath: memory.deletingLastPathComponent().appendingPathComponent(conversation).path))

        // A file that is not the agent's, with no place.
        let notes = await restored(try backup(offer(cwd: cwd.path, files: [MigrationFile(id: "notes", place: "", size: 1, packed: false)]),
                                              files: ["notes.data": Data("x".utf8)]))
        #expect(notes.hasPrefix("Not restored: it carries “notes”"), Comment(rawValue: notes))

        #expect(server.sessions.isEmpty, "nothing started")
        try outsideIsAsItWas()
    }

    /// A backup from before 0.61 holds projects packed beside the agent's
    /// files (`project-<n>`), and lists them: they are left out, said in the
    /// log, and the rest restored, the session's folder made empty.
    @Test func testAnOlderBackupsProjectArchivesAreLeftOut() async throws {
        let cwd = home.appendingPathComponent("Developer/app")
        let other = home.appendingPathComponent("Developer/other")
        let archive = try await tarball([Entry(name: "README.md", text: "x")])
        let log = "{\"type\":\"user\"}\n"
        let files = [MigrationFile(id: "conversation-0", place: "projects/{project}/\(conversation).jsonl", size: log.utf8.count, packed: false),
                     MigrationFile(id: "project-0", place: "", size: archive.count, packed: true),
                     MigrationFile(id: "project-1", place: "", size: archive.count, packed: true)]
        let projects: JSONValue = .array([.object(["path": .string(cwd.path), "commit": .string("abc"), "unshared": .bool(true), "mentions": .number(0)]),
                                          .object(["path": .string(other.path), "commit": .string("abc"), "unshared": .bool(true), "mentions": .number(9)])])
        let outcome = await restored(try backup(offer(cwd: cwd.path, files: files),
                                                files: ["conversation-0.jsonl": Data(log.utf8), "project-0.tgz": archive, "project-1.tgz": archive],
                                                projects: projects))
        #expect(outcome == "Restored.", Comment(rawValue: outcome))
        #expect((try FileManager.default.contentsOfDirectory(atPath: cwd.path)).isEmpty, "its folder made, empty: no project unpacked")
        #expect(!FileManager.default.fileExists(atPath: other.path))
        let placed = ClaudeSessionFiles.projectsRoot(home: home)
            .appendingPathComponent(ClaudeSessionFiles.projectDirectoryName(for: cwd.path), isDirectory: true)
            .appendingPathComponent(conversation + ".jsonl")
        #expect((try String(contentsOf: placed, encoding: .utf8)) == log)
        #expect(server.session("S")?.process.resumeID == conversation)
    }
}
}
