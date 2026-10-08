import ClaudeTranscript
import XCTest

final class ParserTests: XCTestCase {
    let lines = """
    {"type":"queue-operation","operation":"enqueue","uuid":"q1"}
    {"type":"user","uuid":"u1","message":{"role":"user","content":"Use the Bash tool to run sleep"}}
    {"type":"attachment","uuid":"a1"}
    {"type":"assistant","uuid":"a2","message":{"id":"msg_1","model":"claude-fable-5-1","content":[{"type":"thinking","thinking":"…"}],"stop_reason":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":100,"cache_read_input_tokens":2000,"output_tokens":9}}}
    {"type":"assistant","uuid":"a3","message":{"id":"msg_1","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"sleep 4"}}],"stop_reason":"tool_use"}}
    {"type":"user","uuid":"u2","isSidechain":true,"message":{"role":"user","content":"a subagent's prompt"}}
    {"type":"user","uuid":"u2m","isMeta":true,"message":{"role":"user","content":"[Image: original 1206x2622, displayed at 920x2000.]"}}
    {"type":"user","uuid":"u3","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"probe-done"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0KGgo="}}]}]}}
    {"type":"assistant","uuid":"a4","message":{"id":"msg_2","content":[{"type":"text","text":"finished"}],"stop_reason":"end_turn"}}
    {"type":"custom-title","uuid":"t1","customTitle":"probe-title"}
    not json at all
    """

    func testRecords() {
        let records = ClaudeTranscriptParser.records(in: Data(lines.utf8))
        XCTAssertEqual(records.count, 6, "\(records)")
        guard records.count == 6 else { return }
        XCTAssertEqual(records[0].kind, .user(text: "Use the Bash tool to run sleep", images: []))
        if case .assistant(let id, let blocks, _, let model, let usage) = records[1].kind {
            XCTAssertEqual(id, "msg_1"); XCTAssertEqual(blocks, [.thinking]); XCTAssertEqual(model, "claude-fable-5-1")
            XCTAssertEqual(usage?.contextUsed, 2103)
        } else { XCTFail("\(records[1])") }
        if case .assistant(let id, let blocks, let stop, _, _) = records[2].kind {
            XCTAssertEqual(id, "msg_1"); XCTAssertEqual(stop, "tool_use")
            XCTAssertEqual(blocks, [.toolUse(id: "toolu_1", name: "Bash", inputJSON: "{\"command\":\"sleep 4\"}")])
        } else { XCTFail("\(records[2])") }
        if case .toolResult(let toolUseID, let text, let images, let isError) = records[3].kind {
            XCTAssertEqual(toolUseID, "toolu_1"); XCTAssertEqual(text, "probe-done"); XCTAssertFalse(isError)
            XCTAssertEqual(images, [ClaudeImage(base64: "iVBORw0KGgo=", mediaType: "image/png")])
        } else { XCTFail("\(records[3])") }
        XCTAssertEqual(records[4].kind, .assistant(messageID: "msg_2", blocks: [.text("finished")], stopReason: "end_turn", model: nil, usage: nil))
        XCTAssertEqual(records[5].kind, .title("probe title"))
    }

    func testAMessageSentMidTurnIsTheUsers() {
        let line = #"{"type":"attachment","uuid":"m1","parentUuid":"a3","attachment":{"type":"queued_command","prompt":[{"text":"It was a dialog I approved","type":"text"}],"commandMode":"prompt"}}"#
        let parsed = ClaudeTranscriptParser.lines(in: Data(line.utf8))
        XCTAssertEqual(parsed.first?.record?.kind, .user(text: "It was a dialog I approved", images: []))
        XCTAssertEqual(parsed.first?.isPrompt, true)
        // Other attachments are not conversation.
        XCTAssertNil(ClaudeTranscriptParser.lines(in: Data(#"{"type":"attachment","uuid":"x","attachment":{"type":"file"}}"#.utf8)).first?.record)
    }

    /// A goal (`/goal`): the command as the user typed it, the goal set,
    /// and the goal met with why — as Claude Code records them.
    func testAGoalIsTheUsersCommandThenItsState() {
        let command = #"{"type":"user","uuid":"g1","parentUuid":"a1","message":{"role":"user","content":"<command-name>/goal</command-name>\n            <command-message>goal</command-message>\n            <command-args>No jumps when sending</command-args>"}}"#
        let set = #"{"type":"attachment","uuid":"g2","parentUuid":"g1","attachment":{"type":"goal_status","met":false,"sentinel":true,"condition":"No jumps when sending"}}"#
        let met = #"{"type":"attachment","uuid":"g3","parentUuid":"a9","attachment":{"type":"goal_status","met":true,"condition":"No jumps when sending","reason":"Recorded without a jump."}}"#
        let parsed = ClaudeTranscriptParser.lines(in: Data([command, set, met].joined(separator: "\n").utf8))
        XCTAssertEqual(parsed.map(\.record?.kind), [
            .user(text: "/goal No jumps when sending", images: []),
            .goal(condition: "No jumps when sending", met: false, reason: nil),
            .goal(condition: "No jumps when sending", met: true, reason: "Recorded without a jump."),
        ])
        XCTAssertEqual(parsed.first?.isPrompt, true)
        // A command without arguments.
        XCTAssertEqual(ClaudeTranscriptParser.command("<command-name>/compact</command-name><command-args></command-args>"), "/compact")
        XCTAssertNil(ClaudeTranscriptParser.command("Plain words"))
        // An earlier Claude Code's notice of the goal, in the user's place.
        let notice = #"{"type":"user","uuid":"n1","message":{"role":"user","content":"A session-scoped Stop hook is now active with condition: \"In convo, messages sync\""}}"#
        XCTAssertEqual(ClaudeTranscriptParser.lines(in: Data(notice.utf8)).first?.record?.kind,
                       .goal(condition: "In convo, messages sync", met: false, reason: nil))
    }

    func testProjectDirectoryName() {
        XCTAssertEqual(ClaudeSessionFiles.projectDirectoryName(for: "/Users/me/Developer/my_app"), "-Users-me-Developer-my-app")
        // A symlinked folder is named by where it really is.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("link-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real_folder")
        let link = base.appendingPathComponent("alias")
        try? FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(ClaudeSessionFiles.projectDirectoryName(for: link.path),
                       ClaudeSessionFiles.projectDirectoryName(for: real.path))
        XCTAssertTrue(ClaudeSessionFiles.projectDirectoryName(for: link.path).hasSuffix("-real-folder"))
    }

    func testClaudesFolderIsItsConfigDirWhenSet() {
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(ClaudeSessionFiles.configDirectory(home: home, environment: [:]).path, "/Users/me/.claude")
        XCTAssertEqual(ClaudeSessionFiles.configDirectory(home: home, environment: ["CLAUDE_CONFIG_DIR": ""]).path,
                       "/Users/me/.claude")
        XCTAssertEqual(ClaudeSessionFiles.configDirectory(home: home, environment: ["CLAUDE_CONFIG_DIR": "/srv/claude"]).path,
                       "/srv/claude")
    }

    func testTailFollowsAppends() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID().uuidString).jsonl")
        try "".write(to: url, atomically: true, encoding: .utf8)
        let handle = try FileHandle(forWritingTo: url)
        let writing = Task {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"type\":\"user\",\"uuid\":\"u1\",\"message\":{\"content\":\"one\"}}\n{\"type\":\"user\",\"uuid\":\"u2\",\"message\":{\"content\":\"tw".utf8))
            try await Task.sleep(for: .milliseconds(400))
            // The line left half-written is finished: it is handed over whole.
            try handle.write(contentsOf: Data("o\"}}\n".utf8))
        }
        var got: [ClaudeRecord] = []
        var position: UInt64 = 0
        for await batch in FileTail.batches(of: url) {
            got += ClaudeTranscriptParser.records(in: batch.data)
            position = batch.position
            if got.count == 2 { break }
        }
        try await writing.value
        XCTAssertEqual(got.map(\.uuid), ["u1", "u2"])
        XCTAssertEqual(got.last?.kind, .user(text: "two", images: []))
        XCTAssertEqual(position, try handle.seekToEnd(), "the place kept is the end of the last whole line")
    }

    func testTailWaitsForAFileAndFollowsItsPathWhenItIsReplaced() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID().uuidString).jsonl")
        let writing = Task {
            try await Task.sleep(for: .milliseconds(400))
            try Data("first\n".utf8).write(to: url)
            try await Task.sleep(for: .milliseconds(400))
            // Written beside it and moved over it: another file at the
            // path, which holds what the first did and more.
            try Data("first\nsecond\n".utf8).write(to: url, options: .atomic)
            try await Task.sleep(for: .milliseconds(400))
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("third\n".utf8))
        }
        var lines: [String] = []
        for await batch in FileTail.batches(of: url) {
            lines += String(decoding: batch.data, as: UTF8.self).split(separator: "\n").map(String.init)
            if lines.contains("third") { break }
        }
        try await writing.value
        XCTAssertEqual(lines, ["first", "second", "third"])
    }

    // A file as two agents leave it: APPLE, then CHERRY from one and
    // BANANA from the other, BANANA written last.
    private func forkedLines() -> [ClaudeLine] {
        func line(_ type: String, _ uuid: String, _ parent: String?, _ text: String, meta: Bool = false) -> String {
            let content: Any = type == "assistant" ? [["type": "text", "text": text]] : text
            var o: [String: Any] = ["type": type, "uuid": uuid, "message": ["role": type, "content": content]]
            if let parent { o["parentUuid"] = parent }
            if meta { o["isMeta"] = true }
            return String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
        }
        let text = [
            line("user", "p1", nil, "Remember APPLE"),
            line("assistant", "a1", "p1", "OK-APPLE"),
            line("user", "p2", "a1", "Also CHERRY"),
            line("assistant", "a2", "p2", "OK-CHERRY"),
            line("user", "p3", "a1", "Also BANANA"),
            line("user", "m3", "p3", "<system-reminder>", meta: true),
            line("assistant", "a3", "m3", "OK-BANANA"),
        ].joined(separator: "\n")
        return ClaudeTranscriptParser.lines(in: Data(text.utf8))
    }

    func testBranchFollowsTheLastLine() {
        let branch = ClaudeBranch.current(of: forkedLines())
        XCTAssertEqual(branch.records.map(\.uuid), ["p1", "a1", "p3", "a3"])
        XCTAssertEqual(branch.abandoned, ["p2", "a2"])
        XCTAssertEqual(branch.abandonedPrompts, 1)
        XCTAssertEqual(branch.lastPrompt, "p3")
        // Bookkeeping lines count as members: the next line follows one.
        XCTAssertTrue(branch.members.contains("m3"))
        XCTAssertFalse(branch.members.contains("a2"))
    }

    func testBranchKeepsSiblingToolLines() {
        // Two tools called at once: the second call and both results sit
        // beside the chain, and none of them is a fork.
        let text = """
        {"type":"user","uuid":"p1","message":{"role":"user","content":"go"}}
        {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{}}]}}
        {"type":"assistant","uuid":"a2","parentUuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Read","input":{}}]}}
        {"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"one"}]}}
        {"type":"user","uuid":"r2","parentUuid":"a2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"two"}]}}
        {"type":"assistant","uuid":"a3","parentUuid":"r2","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}
        """
        let branch = ClaudeBranch.current(of: ClaudeTranscriptParser.lines(in: Data(text.utf8)))
        XCTAssertTrue(branch.abandoned.isEmpty)
        XCTAssertEqual(branch.records.count, 6)
        XCTAssertEqual(branch.lastPrompt, "p1")
    }
}
