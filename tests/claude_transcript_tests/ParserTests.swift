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

    func testWatcherFollowsAppends() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString).jsonl")
        try "".write(to: url, atomically: true, encoding: .utf8)
        let handle = try FileHandle(forWritingTo: url)
        let seen = expectation(description: "records")
        seen.expectedFulfillmentCount = 2
        var got: [ClaudeRecord] = []
        let lock = NSLock()
        let watcher = ClaudeSessionWatcher(url: url) { lines in
            let records = lines.compactMap(\.record)
            lock.lock(); got += records; lock.unlock()
            for _ in records { seen.fulfill() }
        }
        watcher.start()
        handle.seekToEndOfFile()
        handle.write(Data("{\"type\":\"user\",\"uuid\":\"u1\",\"message\":{\"content\":\"one\"}}\n{\"type\":\"user\",\"uuid\":\"u2\",\"message\":{\"content\":\"tw".utf8))
        Thread.sleep(forTimeInterval: 0.4)
        handle.write(Data("o\"}}\n".utf8))
        wait(for: [seen], timeout: 5)
        watcher.stop()
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(got.map(\.uuid), ["u1", "u2"])
        XCTAssertEqual(got.last?.kind, .user(text: "two", images: []))
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
