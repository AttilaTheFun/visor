// A move's offer is the other server's word, and a server compromised or
// wrong could name `..`, an absolute path, a `/` inside an id, an empty or
// overlong id, a place that is the agent's settings, or an archive whose
// entries lead out or whose links do: the plan refuses such an offer, each
// step refuses such an id or archive with an error, and nothing is written
// outside the move's folder, the agent's place for the conversation, or the
// folder a project's step names. A project's own links that stay inside it
// still come.

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
        VisorServer.storeRoot = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: VisorServer.storeRoot, withIntermediateDirectories: true)
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

    private func offer(resume: String? = nil, cwd: String? = nil, files: [MigrationFile] = [], projects: [MigrationProject] = []) -> MigrationOffer {
        MigrationOffer(token: "t", from: "Elsewhere", session: info(cwd: cwd ?? home.appendingPathComponent("Developer/app").path),
                       resumeID: resume ?? conversation, home: home.path, files: files, projects: projects)
    }

    /// A move as a plan leaves it, made here directly (as if a plan had
    /// taken it), so each step's own checks are what is tried.
    private func move(_ offer: MigrationOffer, steps: [MigrationStep] = []) throws -> URL {
        let folder = VisorServer.migrationsFolder.appendingPathComponent("in-p", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        server.migrationsIn["p"] = IncomingMigration(offer: offer, plan: MigrationPlan(id: "p", cwd: offer.session.cwd, agentInstalled: true, steps: steps),
                                                     folder: folder, created: Date())
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

    /// One entry of a tar archive: a file with `text`, a folder, or a link to `link`.
    private struct Entry {
        var name: String
        var text = ""
        var link: String?
        var folder = false
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
            let body: [UInt8] = entry.link == nil && !entry.folder ? Array(entry.text.utf8) : []
            let type: UInt8 = entry.link != nil ? 0x32 : entry.folder ? 0x35 : 0x30
            var header: [UInt8] = field(entry.name, 100)
            header += octal(entry.folder ? 0o755 : 0o644, 8)
            header += octal(0, 8)
            header += octal(0, 8)
            header += octal(body.count, 12)
            header += octal(0, 12)
            header += [UInt8](repeating: 0x20, count: 8)
            header.append(type)
            header += field(entry.link ?? "", 100)
            header += field("ustar", 6)
            header += Array("00".utf8)
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

    /// `archive` carried as the move's file `project-1` and unpacked as a
    /// copy into `target`.
    private func unpack(_ archive: Data, into target: URL) async throws -> Envelope {
        let step = MigrationStep(project: "/Elsewhere/copied", path: target.path, action: .copy, note: "", chosen: true)
        _ = try move(offer(projects: [MigrationProject(path: "/Elsewhere/copied", commit: "abc", unshared: true)]), steps: [step])
        #expect(write("project-1", archive).type != "error")
        var unpacking = Envelope(type: "migration")
        unpacking.migration = "p"
        unpacking.file = MigrationFile(id: "project-1", place: "", size: archive.count, packed: true)
        unpacking.steps = [step]
        return await server.migrationUnpack(unpacking)
    }

    // MARK: Ids

    @Test func testAHostileFileIdIsRefusedByWriteAndUnpackAndNothingIsWritten() async throws {
        let folder = try move(offer())
        let before = everything()
        for id in hostileIDs {
            let written = write(id, Data("evil".utf8))
            #expect(written.type == "error", "write took \(id.prefix(40))")
        }
        let target = home.appendingPathComponent("Developer/copied", isDirectory: true)
        let step = MigrationStep(project: "/Elsewhere/copied", path: target.path, action: .copy, note: "", chosen: true)
        server.migrationsIn["p"]?.plan.steps = [step]
        for id in hostileIDs {
            var unpacking = Envelope(type: "migration")
            unpacking.migration = "p"
            unpacking.file = MigrationFile(id: id, place: "", size: 0, packed: true)
            unpacking.steps = [step]
            let unpacked = await server.migrationUnpack(unpacking)
            #expect(unpacked.type == "error", "unpack took \(id.prefix(40))")
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
        for path in ["/Users/a/../../etc/cron.d", "x", "/a/b/.."] {
            let refused = await plan(offer(projects: [MigrationProject(path: path)]))
            #expect(refused.plan == nil, "project \(path)")
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
                                              MigrationFile(id: "memory", place: "", size: 1, packed: true)],
                                      projects: [MigrationProject(path: home.appendingPathComponent("Developer/app").path)]))
        #expect(honest.plan != nil, Comment(rawValue: honest.message ?? ""))
        #expect(everything().allSatisfy { !$0.hasSuffix("/x") && !$0.hasSuffix("settings.json") })
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
        let hostile: [(String, [Entry])] = [
            ("../evil", [Entry(name: "ok.txt", text: "fine"), Entry(name: "../evil", text: "evil")]),
            ("deep ../", [Entry(name: "a/../../../../outside/evil", text: "evil")]),
            ("absolute", [Entry(name: outside.appendingPathComponent("evil").path, text: "evil")]),
            ("absolute link", [Entry(name: "link", link: outside.path), Entry(name: "link/evil", text: "evil")]),
            ("link up", [Entry(name: "up", link: "../../../outside")]),
            ("link out, through a link to itself", [Entry(name: "here", link: "."), Entry(name: "out", link: "here/../outside")]),
        ]
        for (what, entries) in hostile {
            let before = everything()
            let unpacked = try await unpack(try await tarball(entries), into: target)
            #expect(unpacked.type == "error", "\(what) unpacked")
            #expect(unpacked.message?.hasPrefix("Could not unpack") == true, Comment(rawValue: unpacked.message ?? ""))
            #expect(!FileManager.default.fileExists(atPath: target.path), "\(what): the folder it made is gone again")
            let made = everything().subtracting(before).filter { !$0.hasPrefix(VisorServer.migrationsFolder.path) }
            #expect(made.isEmpty, "\(what) made \(made)")
            try outsideIsAsItWas()
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("evil").path))
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("evil").path))
        }
    }

    @Test func testAProjectsOwnLinksThatStayInsideItStillCome() async throws {
        let target = home.appendingPathComponent("Developer/copied", isDirectory: true)
        let archive = try await tarball([
            Entry(name: "README.md", text: "read me"),
            Entry(name: "docs", folder: true),
            Entry(name: "docs/readme", link: "../README.md"),
            Entry(name: ".git", folder: true),
            Entry(name: ".git/HEAD", text: "ref: refs/heads/main\n"),
        ])
        let unpacked = try await unpack(archive, into: target)
        #expect(unpacked.type != "error", Comment(rawValue: unpacked.message ?? ""))
        #expect((try String(contentsOf: target.appendingPathComponent("docs/readme"), encoding: .utf8)) == "read me")
        #expect((try FileManager.default.destinationOfSymbolicLink(atPath: target.appendingPathComponent("docs/readme").path)) == "../README.md")
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent(".git/HEAD").path))
        #expect((try FileManager.default.contentsOfDirectory(atPath: target.path)).sorted() == [".git", "README.md", "docs"], "no folder of the unpacking's left")
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
        try await tarball([Entry(name: "memory/MEMORY.md", text: "index")]).write(to: archive)
        #expect(await VisorServer.unpack(archive, into: project, only: "memory") == nil)
        #expect((try String(contentsOf: project.appendingPathComponent("memory/MEMORY.md"), encoding: .utf8)) == "index")
    }

    // MARK: Projects

    @Test func testACloneNeverTakesTheRemoteOrBranchAsAnOption() async throws {
        let target = home.appendingPathComponent("Developer/cloned", isDirectory: true)
        let hostile: [(remote: String, branch: String?)] = [("--upload-pack=touch \(outside.path)/evil", nil),
                                                            ("https://example.com/x.git", "--upload-pack=touch")]
        for (remote, branch) in hostile {
            let step = MigrationStep(project: "/Elsewhere/cloned", path: target.path, action: .clone, note: "", chosen: true)
            _ = try move(offer(projects: [MigrationProject(path: "/Elsewhere/cloned", remote: remote, branch: branch, commit: "abc")]), steps: [step])
            var cloning = Envelope(type: "migration")
            cloning.migration = "p"
            cloning.steps = [step]
            let cloned = await server.migrationClone(cloning)
            #expect(cloned.type == "error")
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
        try outsideIsAsItWas()
    }

    @Test func testARepositoryInTheSourcesIsAlwaysAFolderOfItsOwnThere() {
        let folders = SessionFolders(sessions: "/Volumes/Sessions", sources: "/Volumes/Sources")
        #expect(folders.source(for: "/Users/a/..") == nil)
        #expect(folders.source(for: "/Users/a/.") == nil)
        #expect(folders.source(for: "/") == nil)
        #expect(folders.source(for: "/Users/a/visor") == "/Volumes/Sources/visor")
        #expect(server.notAProjectPlace("/") != nil)
        #expect(server.notAProjectPlace("/a/../b") != nil)
        #expect(server.notAProjectPlace(home.appendingPathComponent("Developer/x").path) == nil)
    }
}
}
