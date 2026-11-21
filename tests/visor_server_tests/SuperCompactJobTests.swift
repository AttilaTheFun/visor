// Super Compact's job (VisorServer+SuperCompact, SuperCompaction), run
// with a fake `claude` that answers each step with canned text and logs
// how it was called: the cascade from the prefilter through the map
// (Haiku), the merge (Sonnet, in levels) and the final step (Opus) to
// HANDOFF.md and the check's warning; a job the server went away under
// mid-map carrying on from its last chunk; a cancel; a failed job and
// it carried on; one job at a time; and admin-only, as every REST route.

import ClaudeTranscript
import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Testing

extension ServerTests {
@Suite @MainActor final class SuperCompactJobTests {
    private var server: VisorServer!
    private let root: URL
    private let home: URL
    private let bin: URL
    private let savedHome: URL
    private let conversation = "abcdabcd-1111-2222-3333-444444444444"

    init() throws {
        TestPlatform.install()
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("visor-super-compact-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: String(cString: try #require(realpath(made.path, nil))), isDirectory: true)
        VisorServer.storeRoot = root.appendingPathComponent("data", isDirectory: true)
        VisorServer.secrets = MemorySecrets()
        savedHome = ClaudeSessionFiles.home
        home = root.appendingPathComponent("home", isDirectory: true)
        ClaudeSessionFiles.home = home
        bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Self.fakeClaude.write(to: bin.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("claude").path)
        VisorServer.superCompactTool = bin.appendingPathComponent("claude").path
        server = VisorServer(port: ServerTestCase.freePort())
        server.password = "pw"
        // Small chunks (a thousand tokens, the least) in pairs: four
        // chunks, then a merge of two levels (two, then one).
        var settings = SuperCompactSettings()
        settings.chunkTokens = 1
        settings.mergeGroup = 2
        server.settings.superCompact = settings
    }

    isolated deinit {
        server.haltSuperCompaction()
        server.stop()
        VisorServer.superCompactTool = nil
        ClaudeSessionFiles.home = savedHome
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: The fake claude

    /// Logs each call's model and first line (calls.log) and its arguments
    /// (args.log), and answers its step. With `hang` in its folder, the
    /// call for chunk 2 never ends; with `fail`, every call fails.
    static let fakeClaude = #"""
        #!/bin/sh
        dir="$(dirname "$0")"
        input="$dir/input.$$"
        cat > "$input"
        first=$(head -n 1 "$input")
        rm -f "$input"
        model=""; prev=""
        for a in "$@"; do
          if [ "$prev" = "--model" ]; then model="$a"; fi
          prev="$a"
        done
        for a in "$@"; do printf '[%s]\n' "$a"; done > "$dir/args.log"
        printf '%s | %s | %s\n' "$model" "$first" "$(pwd)" >> "$dir/calls.log"
        case "$first" in
          *"MAP, CHUNK 2 OF"*) if [ -f "$dir/hang" ]; then exec sleep 30; fi ;;
        esac
        if [ -f "$dir/fail" ]; then echo "boom" >&2; exit 1; fi
        case "$first" in
          *MAP*) printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"=== LEDGER ===\n## Rules and decisions\n- [2026-11-20] \"Never force-push\" to main\n=== CHAPTER ===\n## 2026-11-20: a chapter"}' ;;
          *MERGE*) printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"=== LEDGER ===\n## Rules and decisions\n- [2026-11-20] \"Never force-push\" to main\n- [2026-11-20] Ship release 0.64 on Friday\n## Current state\n- fine\n=== TIMELINE ===\n## 2026-11-20: merged"}' ;;
          *FINAL*) printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"```markdown\n# Handoff: App\n\n## Rules and decisions\n- 2026-11-20: never force-push to main\n```"}' ;;
        esac
        """#

    private var calls: [String] {
        ((try? String(contentsOf: bin.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func flag(_ name: String, _ on: Bool) throws {
        let file = bin.appendingPathComponent(name)
        if on { try Data().write(to: file) } else { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: Sessions and requests

    private var cwd: URL { home.appendingPathComponent("Developer/app", isDirectory: true) }

    /// A Claude session with a conversation of `messages` of the person's,
    /// enough for four chunks at the least size.
    @discardableResult
    private func session(_ id: String, messages: Int = 32) throws -> SessionRecord {
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let file = ClaudeSessionFiles.expectedURL(sessionID: conversation, cwd: cwd.path, home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = (1...messages).map { index in
            #"{"type":"user","timestamp":"2026-11-20T09:00:00.000Z","message":{"role":"user","content":"Message \#(index): "#
                + String(repeating: "words ", count: 70) + #""}}"#
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        let info = SessionInfo(id: id, agent: .claude, cwd: cwd.path, title: "App", created: 0)
        let record = SessionRecord(info: info, process: ClaudeProcess(cwd: cwd.path, skipPermissions: true, resume: conversation))
        server.sessions.append(record)
        return record
    }

    private func rest(_ method: String, _ session: String, bearer: String? = "pw") -> HTTPResponse {
        server.route(HTTPRequest(method: method, path: "/api/sessions/\(session)/super-compact",
                                 headers: bearer.map { ["authorization": "Bearer " + $0] } ?? [:], body: ""))
    }

    private func job(_ response: HTTPResponse) throws -> SuperCompactJob {
        try JSONDecoder().decode(SuperCompactJob.self, from: Data(response.body.utf8))
    }

    private func until(_ what: String, within seconds: Double = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { Issue.record("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The running job, waited for to its end.
    private func finish() async throws -> SuperCompactJob {
        let running = try #require(server.superCompaction)
        await running.ended()
        return running.job
    }

    // MARK: Tests

    /// The whole cascade: the prefilter's chunks, each mapped by Haiku with
    /// the ledger carried forward, merged by Sonnet in two levels, and
    /// HANDOFF.md by Opus — each call `claude -p` with no tools and no MCP,
    /// in the job's folder; then the check warns of the rule the handoff
    /// left out.
    @Test func aJobRunsTheCascadeToTheHandoff() async throws {
        try session("s1")
        #expect(rest("GET", "s1").status == 404)
        let started = rest("POST", "s1")
        #expect(started.status == 202, "\(started.body)")
        let begun = try job(started)
        #expect(begun.session == "s1")
        #expect(begun.conversation == conversation)
        let ended = try await finish()
        #expect(ended.phase == .done, "\(ended.error ?? "")")
        #expect(ended.chunks == 4)
        #expect(ended.chunk == 4)
        #expect(ended.mergeSteps == 3)
        #expect(ended.mergeStep == 3)
        let status = try job(rest("GET", "s1"))
        #expect(status == ended)

        let models = calls.map { $0.components(separatedBy: " | ") }
        #expect(models.map { $0[0] + " " + $0[1] } == [
            "haiku SUPER COMPACT MAP, CHUNK 1 OF 4", "haiku SUPER COMPACT MAP, CHUNK 2 OF 4",
            "haiku SUPER COMPACT MAP, CHUNK 3 OF 4", "haiku SUPER COMPACT MAP, CHUNK 4 OF 4",
            "sonnet SUPER COMPACT MERGE, LEVEL 1, STEP 1 OF 3", "sonnet SUPER COMPACT MERGE, LEVEL 1, STEP 2 OF 3",
            "sonnet SUPER COMPACT MERGE, LEVEL 2, STEP 3 OF 3", "opus SUPER COMPACT FINAL",
        ])
        #expect(models.allSatisfy { $0[2] == ended.folder }, "each call runs in the job's folder")
        let arguments = try String(contentsOf: bin.appendingPathComponent("args.log"), encoding: .utf8)
        for expected in ["[-p]\n", "[--tools]\n[]\n", "[--strict-mcp-config]\n", "[--mcp-config]\n[{\"mcpServers\":{}}]\n", "[--safe-mode]\n",
                         "[--no-session-persistence]\n", "[--output-format]\n[json]\n", "[--system-prompt]\n"] {
            #expect(arguments.contains(expected), "\(expected) in \(arguments)")
        }

        let folder = ended.folderURL
        #expect(ended.folder.hasPrefix(VisorServer.superCompactRoot.appendingPathComponent("s1").path))
        let handoff = try String(contentsOf: URL(fileURLWithPath: try #require(ended.handoff)), encoding: .utf8)
        #expect(handoff == "# Handoff: App\n\n## Rules and decisions\n- 2026-11-20: never force-push to main\n", "the fence taken off")
        for file in ["chunks/0004.txt", "map/0001.md", "map/0004.md", "merge/1-0002.md", "merge/2-0001.md", "ledger.md", "timeline.md", "job.json"] {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path), "\(file)")
        }
        #expect(ended.warnings.count == 1)
        #expect(ended.warnings.first?.contains("1 of the ledger's 2 rules and decisions") == true, "\(ended.warnings)")
        #expect(ended.warnings.first?.contains("Ship release 0.64 on Friday") == true)
        #expect(server.superCompaction == nil)
    }

    /// The jobs' folders are their owner's alone (0700), down to each
    /// job's: they hold the conversation's text, and the first lines of
    /// its tools' results can carry tokens. One there already is made so.
    @Test func theFoldersAreTheOwnersAlone() async throws {
        try session("s1")
        try FileManager.default.createDirectory(at: VisorServer.superCompactRoot, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let begun = try job(rest("POST", "s1"))
        let ended = try await finish()
        #expect(ended.phase == .done, "\(ended.error ?? "")")
        let folders = [VisorServer.superCompactRoot, VisorServer.superCompactRoot.appendingPathComponent("s1"), begun.folderURL]
        for folder in folders {
            let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o700, "\(folder.path): \(String(mode?.intValue ?? 0, radix: 8))")
        }
    }

    /// The server went away mid-map (halted, as it is when it steps aside
    /// or quits): the next server carries the job on from the last chunk
    /// finished, not from the start.
    @Test func aJobCarriesOnAfterTheServerWentAwayMidMap() async throws {
        try session("s1")
        try flag("hang", true)
        #expect(rest("POST", "s1").status == 202)
        try await until("chunk 2") { calls.contains { $0.contains("CHUNK 2 OF 4") } }
        let running = try #require(server.superCompaction)
        server.haltSuperCompaction()
        await running.ended()
        let kept = try #require(SuperCompactJob.kept(in: running.job.folderURL))
        #expect(kept.phase == .map)
        #expect(kept.chunk == 1)

        try flag("hang", false)
        server.stop()
        server = VisorServer(port: ServerTestCase.freePort())
        server.resumeSuperCompaction()
        let ended = try await finish()
        #expect(ended.id == kept.id)
        #expect(ended.phase == .done)
        let maps = calls.filter { $0.contains("MAP") }.map { $0.components(separatedBy: " | ")[1] }
        #expect(maps == ["SUPER COMPACT MAP, CHUNK 1 OF 4", "SUPER COMPACT MAP, CHUNK 2 OF 4", "SUPER COMPACT MAP, CHUNK 2 OF 4",
                         "SUPER COMPACT MAP, CHUNK 3 OF 4", "SUPER COMPACT MAP, CHUNK 4 OF 4"])
    }

    /// Cancelled, the call under way is ended at once and the job is over
    /// for good: not carried on, and a new one may start.
    @Test func aCancelledJobEndsForGood() async throws {
        try session("s1")
        try flag("hang", true)
        #expect(rest("POST", "s1").status == 202)
        try await until("chunk 2") { calls.contains { $0.contains("CHUNK 2 OF 4") } }
        let running = try #require(server.superCompaction)
        let clock = ContinuousClock()
        let began = clock.now
        let cancelled = rest("DELETE", "s1")
        #expect(cancelled.status == 200)
        #expect(try job(cancelled).phase == .cancelled)
        await running.ended()
        #expect(clock.now - began < .seconds(10), "the hung call was ended, not waited for")
        #expect(server.superCompaction == nil)
        #expect(try job(rest("GET", "s1")).phase == .cancelled)
        #expect(rest("DELETE", "s1").status == 404)
        server.resumeSuperCompaction()
        #expect(server.superCompaction == nil, "a cancelled job is not carried on")

        try flag("hang", false)
        let again = rest("POST", "s1")
        #expect(again.status == 202)
        #expect(try job(again).id != running.job.id)
        #expect(try await finish().phase == .done)
    }

    /// Each call is tried again, then the job fails, saying why in its
    /// status; started again, it carries on where it failed.
    @Test func aFailedJobSaysWhyAndCarriesOnWhenStartedAgain() async throws {
        try session("s1")
        try flag("fail", true)
        #expect(rest("POST", "s1").status == 202)
        let failed = try await finish()
        #expect(failed.phase == .failed)
        #expect(failed.failedIn == .map)
        #expect(failed.error?.contains("chunk 1 of 4") == true, "\(failed.error ?? "")")
        #expect(failed.error?.contains("boom") == true, "\(failed.error ?? "")")
        #expect(calls.count == 3, "three attempts")
        #expect(try job(rest("GET", "s1")).phase == .failed)

        try flag("fail", false)
        let again = rest("POST", "s1")
        #expect(again.status == 202)
        let ended = try await finish()
        #expect(ended.id == failed.id)
        #expect(ended.phase == .done)
        #expect(ended.error == nil)
    }

    /// One at a time per server: a second job, of this session or another,
    /// is refused while one runs.
    @Test func aSecondJobIsRefusedWhileOneRuns() async throws {
        try session("s1")
        let other = SessionRecord(info: SessionInfo(id: "s2", agent: .claude, cwd: cwd.path, title: "Other", created: 0),
                                  process: ClaudeProcess(cwd: cwd.path, skipPermissions: true, resume: conversation))
        server.sessions.append(other)
        try flag("hang", true)
        #expect(rest("POST", "s1").status == 202)
        try await until("chunk 2") { calls.contains { $0.contains("CHUNK 2 OF 4") } }
        for session in ["s1", "s2"] {
            let refused = rest("POST", session)
            #expect(refused.status == 409)
            #expect(refused.body.contains("one at a time"), "\(refused.body)")
        }
        #expect(rest("GET", "s2").status == 404)
        #expect(rest("DELETE", "s2").status == 404, "s2's own: none runs")
        let running = try #require(server.superCompaction)
        #expect(rest("DELETE", "s1").status == 200)
        await running.ended()
        try flag("hang", false)
        #expect(rest("POST", "s2").status == 202)
        #expect(try await finish().phase == .done)
    }

    /// Admin-only, as every REST route: no credentials, no job.
    @Test func itIsTheAdminsAlone() throws {
        try session("s1")
        #expect(rest("POST", "s1", bearer: nil).status == 401)
        #expect(rest("GET", "s1", bearer: "wrong").status == 401)
        #expect(server.superCompaction == nil)
        #expect(rest("POST", "nope").status == 404)
    }

    /// The merge's levels: groups of the group's size, then groups of
    /// those, down to one, and one level even for a single chunk.
    @Test func theMergeGoesDownInLevelsToOne() {
        #expect(SuperCompaction.mergeLevels(count: 1, group: 8) == [1])
        #expect(SuperCompaction.mergeLevels(count: 8, group: 8) == [1])
        #expect(SuperCompaction.mergeLevels(count: 9, group: 8) == [2, 1])
        #expect(SuperCompaction.mergeLevels(count: 300, group: 8) == [38, 5, 1])
    }

    /// The check: a rule is mentioned when its identifiers all are and
    /// half its telling words; one that isn't is named.
    @Test func theCheckNamesTheRulesLeftOut() {
        let ledger = """
            ## Rules and decisions
            - [2026-11-15] "No Visor install, deploy or restart" while Logan is away
            - [2026-11-16] Merge #421 only after the review
              (continued on a second line)
            ## Current state
            - [2026-11-20] not a rule
            """
        let handoff = "Logan said: no Visor install, deploy or restart while away. Current state is fine."
        let warnings = SuperCompactCheck.warnings(ledger: ledger, handoff: handoff)
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("1 of the ledger's 2") == true)
        #expect(warnings.first?.contains("Merge #421 only after the review (continued on a second line)") == true, "\(warnings)")
        #expect(SuperCompactCheck.warnings(ledger: ledger, handoff: handoff + " Merge #421 after the review; it continued on a second line.").isEmpty)
    }

    /// The settings: the aliases by default; a file without them, or with
    /// some, reads as the defaults for the rest.
    @Test func theSettingsDefaultToTheAliases() throws {
        let defaults = SuperCompactSettings()
        #expect([defaults.mapModel, defaults.mergeModel, defaults.finalModel] == ["haiku", "sonnet", "opus"])
        #expect(defaults.chunkCharacters == 480_000)
        let some = try JSONDecoder().decode(SuperCompactSettings.self, from: Data(#"{"finalModel":"claude-opus-5-5","mapModel":""}"#.utf8))
        #expect([some.mapModel, some.mergeModel, some.finalModel] == ["haiku", "sonnet", "claude-opus-5-5"])
        var settings = ServerSettings()
        #expect(settings.superCompact == nil)
        settings.superCompact = some
        let read = try JSONDecoder().decode(ServerSettings.self, from: JSONEncoder().encode(settings))
        #expect(read.superCompact == some)
    }
}
}
