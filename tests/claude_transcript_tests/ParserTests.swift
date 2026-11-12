import ClaudeTranscript
import Foundation
import Testing

@Suite final class ParserTests {
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

    @Test func testRecords() {
        let records = ClaudeTranscriptParser.records(in: Data(lines.utf8))
        #expect(records.count == 6, "\(records)")
        guard records.count == 6 else { return }
        #expect((records[0].kind) == .user(text: "Use the Bash tool to run sleep", images: []))
        if case .assistant(let id, let blocks, _, let model, let usage) = records[1].kind {
            #expect(id == "msg_1"); #expect(blocks == [.thinking]); #expect(model == "claude-fable-5-1")
            #expect((usage?.contextUsed) == 2103)
        } else { Issue.record("\(records[1])") }
        if case .assistant(let id, let blocks, let stop, _, _) = records[2].kind {
            #expect(id == "msg_1"); #expect(stop == "tool_use")
            #expect(blocks == [.toolUse(id: "toolu_1", name: "Bash", inputJSON: "{\"command\":\"sleep 4\"}")])
        } else { Issue.record("\(records[2])") }
        if case .toolResult(let toolUseID, let text, let images, let isError) = records[3].kind {
            #expect(toolUseID == "toolu_1"); #expect(text == "probe-done"); #expect(!isError)
            #expect(images == [ClaudeImage(base64: "iVBORw0KGgo=", mediaType: "image/png")])
        } else { Issue.record("\(records[3])") }
        #expect((records[4].kind) == (.assistant(messageID: "msg_2", blocks: [.text("finished")], stopReason: "end_turn", model: nil, usage: nil)))
        #expect((records[5].kind) == .title("probe title"))
    }

    /// The answers to the agent's questions (AskUserQuestion) are the
    /// user's, in the order asked, read from what Claude Code keeps beside
    /// the tool's result.
    @Test func testAnswersToTheAgentsQuestionsAreTheUsers() {
        let line = #"{"type":"user","uuid":"u9","toolUseResult":{"questions":[{"question":"Which color?","header":"Color","options":[]},{"question":"How big?","header":"Size","options":[]}],"answers":{"How big?":"Large","Which color?":"Blue"}},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_9","content":"Your questions have been answered"}]}}"#
        let records = ClaudeTranscriptParser.records(in: Data(line.utf8))
        #expect((records.first?.kind) == (.answers([ClaudeAnswer(question: "Which color?", answer: "Blue"),
                                                      ClaudeAnswer(question: "How big?", answer: "Large")])))
        #expect(ClaudeTranscriptParser.answers(["stdout": "x"]) == nil, "another tool's result")
    }

    @Test func testAMessageSentMidTurnIsTheUsers() {
        let line = #"{"type":"attachment","uuid":"m1","parentUuid":"a3","attachment":{"type":"queued_command","prompt":[{"text":"It was a dialog I approved","type":"text"}],"commandMode":"prompt"}}"#
        let parsed = ClaudeTranscriptParser.lines(in: Data(line.utf8))
        #expect((parsed.first?.record?.kind) == .user(text: "It was a dialog I approved", images: []))
        #expect((parsed.first?.isPrompt) == true)
        // Other attachments are not conversation.
        #expect((ClaudeTranscriptParser.lines(in: Data(#"{"type":"attachment","uuid":"x","attachment":{"type":"file"}}"#.utf8)).first?.record) == nil)
    }

    /// A goal (`/goal`): the command as the user typed it, the goal set,
    /// and the goal met with why — as Claude Code records them.
    @Test func testAGoalIsTheUsersCommandThenItsState() {
        let command = #"{"type":"user","uuid":"g1","parentUuid":"a1","message":{"role":"user","content":"<command-name>/goal</command-name>\n            <command-message>goal</command-message>\n            <command-args>No jumps when sending</command-args>"}}"#
        let set = #"{"type":"attachment","uuid":"g2","parentUuid":"g1","attachment":{"type":"goal_status","met":false,"sentinel":true,"condition":"No jumps when sending"}}"#
        let met = #"{"type":"attachment","uuid":"g3","parentUuid":"a9","attachment":{"type":"goal_status","met":true,"condition":"No jumps when sending","reason":"Recorded without a jump."}}"#
        let parsed = ClaudeTranscriptParser.lines(in: Data([command, set, met].joined(separator: "\n").utf8))
        #expect(parsed.map(\.record?.kind) == ([
            .user(text: "/goal No jumps when sending", images: []),
            .goal(condition: "No jumps when sending", met: false, reason: nil),
            .goal(condition: "No jumps when sending", met: true, reason: "Recorded without a jump."),
        ]))
        #expect((parsed.first?.isPrompt) == true)
        // A command without arguments.
        #expect(ClaudeTranscriptParser.command("<command-name>/compact</command-name><command-args></command-args>") == "/compact")
        #expect(ClaudeTranscriptParser.command("Plain words") == nil)
        // An earlier Claude Code's notice of the goal, in the user's place.
        let notice = #"{"type":"user","uuid":"n1","message":{"role":"user","content":"A session-scoped Stop hook is now active with condition: \"In convo, messages sync\""}}"#
        #expect((ClaudeTranscriptParser.lines(in: Data(notice.utf8)).first?.record?.kind) == .goal(condition: "In convo, messages sync", met: false, reason: nil))
    }

    @Test func testTheTailOfALargeConversationIsItsLastWholeLines() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        var text = ""
        for index in 0..<1_000 {
            text += #"{"type":"user","uuid":"u\#(index)","message":{"role":"user","content":"message \#(index)"}}"# + "\n"
        }
        try Data(text.utf8).write(to: file)
        let whole = ClaudeTranscriptParser.lines(contentsOf: file)
        #expect(whole.count == 1_000)
        // About the last 50 lines' worth of bytes: only whole lines, ending
        // with the file's last.
        let tail = ClaudeTranscriptParser.tailLines(contentsOf: file, bytes: 50 * 90)
        #expect(tail.count > 40)
        #expect(tail.count < 60)
        #expect(tail.map(\.uuid).last == whole.map(\.uuid).last)
        #expect((Array(whole.suffix(tail.count)).map(\.uuid)) == tail.map(\.uuid), "the same lines as the end of the whole")
        #expect(ClaudeTranscriptParser.tailLines(contentsOf: file, bytes: 10 << 20).count == 1_000, "a small file is read whole")
    }

    @Test func testProjectDirectoryName() {
        #expect(ClaudeSessionFiles.projectDirectoryName(for: "/Users/me/Developer/my_app") == "-Users-me-Developer-my-app")
        // A symlinked folder is named by where it really is.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("link-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real_folder")
        let link = base.appendingPathComponent("alias")
        try? FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(ClaudeSessionFiles.projectDirectoryName(for: link.path) == ClaudeSessionFiles.projectDirectoryName(for: real.path))
        #expect(ClaudeSessionFiles.projectDirectoryName(for: link.path).hasSuffix("-real-folder"))
    }

    @Test func testClaudesFolderIsItsConfigDirWhenSet() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(ClaudeSessionFiles.configDirectory(home: home, environment: [:]).path == "/Users/me/.claude")
        #expect(ClaudeSessionFiles.configDirectory(home: home, environment: ["CLAUDE_CONFIG_DIR": ""]).path == "/Users/me/.claude")
        #expect(ClaudeSessionFiles.configDirectory(home: home, environment: ["CLAUDE_CONFIG_DIR": "/srv/claude"]).path == "/srv/claude")
    }

    @Test func testTailFollowsAppends() async throws {
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
        #expect(got.map(\.uuid) == ["u1", "u2"])
        #expect((got.last?.kind) == .user(text: "two", images: []))
        #expect(position == (try handle.seekToEnd()), "the place kept is the end of the last whole line")
    }

    @Test func testTailWaitsForAFileAndFollowsItsPathWhenItIsReplaced() async throws {
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
        #expect(lines == ["first", "second", "third"])
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

    @Test func testBranchFollowsTheLastLine() {
        let branch = ClaudeBranch.current(of: forkedLines())
        #expect(branch.records.map(\.uuid) == ["p1", "a1", "p3", "a3"])
        #expect(branch.abandoned == ["p2", "a2"])
        #expect(branch.abandonedPrompts == 1)
        #expect(branch.lastPrompt == "p3")
        // Bookkeeping lines count as members: the next line follows one.
        #expect(branch.members.contains("m3"))
        #expect(!branch.members.contains("a2"))
    }

    @Test func testBranchKeepsSiblingToolLines() {
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
        #expect(branch.abandoned.isEmpty)
        #expect(branch.records.count == 6)
        #expect(branch.lastPrompt == "p1")
    }
    private func nodes(_ lines: [ClaudeLine]) -> [ClaudeBranch.Node] {
        lines.map { ClaudeBranch.Node(uuid: $0.uuid, parentUuid: $0.parentUuid, isPrompt: $0.isPrompt, isMessage: $0.isMessage) }
    }

    @Test func testALineBesideAnOlderMessageDecidesNothing() {
        // Claude Code writes attachments between messages, and one may
        // hang off an older message: the newest message decides the
        // branch, not the last line.
        let text = """
        {"type":"user","uuid":"p1","message":{"role":"user","content":"one"}}
        {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"role":"assistant","content":[{"type":"text","text":"1"}]}}
        {"type":"user","uuid":"p2","parentUuid":"a1","message":{"role":"user","content":"two"}}
        {"type":"assistant","uuid":"a2","parentUuid":"p2","message":{"role":"assistant","content":[{"type":"text","text":"2"}]}}
        {"type":"attachment","uuid":"x","parentUuid":"a1","attachment":{"type":"deferred_tools_record"}}
        """
        let branch = ClaudeBranch.current(of: ClaudeTranscriptParser.lines(in: Data(text.utf8)))
        #expect(branch.abandoned.isEmpty)
        #expect(branch.lastPrompt == "p2")
    }

    @Test func testAHeadKeepsToItsBranchWhenTheFileGoesOnElsewhere() {
        // Visor's conversation is APPLE then CHERRY (its head, p2); another
        // agent then wrote BANANA from APPLE, last.
        let kept = ClaudeBranch.current(nodes: nodes(forkedLines()), head: "p2")
        #expect(kept.abandoned == ["p3", "m3", "a3"])
        #expect(kept.head == "p2")
        #expect(kept.leaf == "a2", "where its agent resumes")
        #expect(kept.wentOnElsewhere)
        // With no head, the newest message decides, as Claude Code's
        // own resume would.
        let plain = ClaudeBranch.current(nodes: nodes(forkedLines()))
        #expect(plain.head == "p3")
        #expect(plain.leaf == "a3")
        #expect(!plain.wentOnElsewhere)
    }

    @Test func testAHeadFollowsWhatCarriesOnFromIt() {
        // Two tools at once, then a turn from beside the first result (a
        // terminal resuming the same conversation): all of it carries on
        // from the head's turn.
        let text = """
        {"type":"user","uuid":"p1","message":{"role":"user","content":"go"}}
        {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{}}]}}
        {"type":"assistant","uuid":"a2","parentUuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Read","input":{}}]}}
        {"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"one"}]}}
        {"type":"user","uuid":"r2","parentUuid":"a2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"two"}]}}
        {"type":"assistant","uuid":"a3","parentUuid":"r2","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}
        {"type":"user","uuid":"p2","parentUuid":"a3","message":{"role":"user","content":"and then"}}
        {"type":"assistant","uuid":"a4","parentUuid":"p2","message":{"role":"assistant","content":[{"type":"text","text":"then"}]}}
        """
        let shape = ClaudeBranch.current(nodes: nodes(ClaudeTranscriptParser.lines(in: Data(text.utf8))), head: "p1")
        #expect(shape.abandoned.isEmpty)
        #expect(shape.head == "p2")
        #expect(shape.leaf == "a4")
        #expect(!shape.wentOnElsewhere)
    }
}
