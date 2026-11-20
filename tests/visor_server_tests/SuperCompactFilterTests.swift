// Super Compact's prefilter (SuperCompactFilter): a small synthetic
// conversation with a line of every kind kept and dropped — the person's
// words, the agent's replies, tool calls and their results (one huge),
// Claude's compaction summary and its boundary, mail in each of its
// forms, images, thinking, system reminders, sidechains and bookkeeping —
// read to the golden text. And the file is streamed, a piece at a time,
// to the snapshot's end alone, into chunks that never cut an entry.

import Foundation
@testable import VisorServer
import Testing

extension ServerTests {
@Suite @MainActor final class SuperCompactFilterTests {
    private let folder: URL

    init() throws {
        TestPlatform.install()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("visor-super-compact-filter-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    // MARK: The conversation

    private static func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func user(_ content: Any, at time: String, extra: [String: Any] = [:]) -> String {
        line(["type": "user", "isSidechain": false, "timestamp": "2026-11-20T\(time):00.000Z",
              "message": ["role": "user", "content": content]].merging(extra) { _, new in new })
    }

    private static func assistant(_ blocks: [[String: Any]], at time: String, extra: [String: Any] = [:]) -> String {
        line(["type": "assistant", "isSidechain": false, "timestamp": "2026-11-20T\(time):00.000Z",
              "message": ["role": "assistant", "content": blocks]].merging(extra) { _, new in new })
    }

    static let picture = ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": String(repeating: "iVBORw0KGgo", count: 2_000)]] as [String: Any]
    static let huge = (1...1_000).map { "output line \($0)" }.joined(separator: "\n")

    static var lines: [String] {
        [
            // Bookkeeping: passed over, unread.
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-20T08:59:00.000Z"}"#,
            #"{"type":"api-request-blob","message":{"role":"user","content":[{"type":"text","text":"PERSON: not this"}]}}"#,
            line(["type": "attachment", "timestamp": "2026-11-20T09:00:00.000Z",
                  "attachment": ["type": "date", "date": "2026-11-20"]]),
            // The person, a reminder around their words.
            user("<system-reminder>\nToday's date is 2026-11-20.\n</system-reminder>\nShip 0.64 today. Never force-push.", at: "09:00"),
            // Thinking, then a reply and a call.
            assistant([["type": "thinking", "thinking": "secret thoughts", "signature": "x"]], at: "09:01"),
            assistant([["type": "text", "text": "On it."],
                       ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "git status -sb\ngit log -1", "description": "Status"]]],
                      at: "09:01"),
            // A huge result: its first lines.
            user([["type": "tool_result", "tool_use_id": "t1", "content": huge]], at: "09:02"),
            // A failed one with a reminder in it.
            user([["type": "tool_result", "tool_use_id": "t2", "is_error": true,
                   "content": "Exit code 1\n<system-reminder>\nboilerplate\n</system-reminder>"]], at: "09:02"),
            // A picture the person sent, and one a tool returned.
            user([["type": "text", "text": "Look at this"], picture], at: "09:03"),
            user([["type": "tool_result", "tool_use_id": "t3", "content": [picture]]], at: "09:03"),
            // Claude Code's own description of the picture: not theirs.
            user("[Image: original 2436x1125]", at: "09:03", extra: ["isMeta": true]),
            // A subagent's sidechain.
            assistant([["type": "text", "text": "subagent words"]], at: "09:04", extra: ["isSidechain": true]),
            // The compaction: its boundary, then its summary.
            line(["type": "system", "subtype": "compact_boundary", "content": "Conversation compacted", "timestamp": "2026-11-20T10:00:00.000Z",
                  "compactMetadata": ["trigger": "auto", "preTokens": 966_999]]),
            user("This session is being continued from a previous conversation.\n\n<system-reminder>\n<tools-used-before-summary>Bash</tools-used-before-summary>\n</system-reminder>\nSummary:\n1. Primary Request: ship 0.64.",
                 at: "10:00", extra: ["isCompactSummary": true]),
            // Mail: headed with its sender, `@@from`, the inbox's notice, `@@to`, send_message.
            user("[Message from the Visor session “Isomer” (0vgy) on Logan’s MacBook Pro (server abc), to this session “Visor” (xyz) on Mini — not from the user. To answer, use send_message with session 0vgy and server abc.]\n\nPR #9 is merged.\nMore below.",
                 at: "10:05"),
            user("@@from Isomer on MacBook\n\nHello there", at: "10:06"),
            user("[Visor: you have 2 messages in your inbox; read them with read_inbox]", at: "10:07"),
            assistant([["type": "text", "text": "@@to Isomer on MacBook\n\nThanks, rebasing."]], at: "10:08"),
            assistant([["type": "tool_use", "id": "t4", "name": "mcp__visor__send_message",
                        "input": ["session": "0vgy", "server": "abc", "text": "Please rebase\nonto main"]]], at: "10:09"),
            // A message queued while the agent worked; a slash command; answers; a task's end.
            line(["type": "attachment", "timestamp": "2026-11-20T10:10:00.000Z",
                  "attachment": ["type": "queued_command", "prompt": "Also bump the version", "commandMode": "prompt"]]),
            user("<command-name>/goal</command-name>\n<command-args>ship it</command-args>", at: "10:11"),
            user([["type": "tool_result", "tool_use_id": "t5", "content": "answered"]], at: "10:12",
                 extra: ["toolUseResult": ["questions": [["question": "Which?"]], "answers": ["Which?": "The first"]]]),
            user("<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n<summary>Background build finished</summary>\n</task-notification>",
                 at: "10:13"),
            assistant([["type": "tool_use", "id": "t6", "name": "mcp__visor__gh__pr_create",
                        "input": ["repo": "AttilaTheFun/visor", "title": "Super Compact", "body": "long body", "base": "main"]]], at: "10:14"),
        ]
    }

    static let golden = """
        [2026-11-20 09:00] PERSON: Ship 0.64 today. Never force-push.
        [2026-11-20 09:01] AGENT: On it.
        [2026-11-20 09:01] TOOL Bash: git status -sb git log -1 description=Status
        [2026-11-20 09:02] → output line 1 ⏎ output line 2 ⏎ output line 3 ⏎ output line 4 … (+996 lines)
        [2026-11-20 09:02] → ERROR: Exit code 1
        [2026-11-20 09:03] PERSON: Look at this [1 image dropped]
        [2026-11-20 09:03] → [1 image dropped]
        [2026-11-20 10:00] --- Claude Code compacted the conversation here (auto, 966999 tokens before) ---
        [2026-11-20 10:00] CLAUDE'S COMPACTION SUMMARY:
        This session is being continued from a previous conversation.

        Summary:
        1. Primary Request: ship 0.64.
        [2026-11-20 10:05] MAIL FROM “Isomer” (0vgy): PR #9 is merged. More below.
        [2026-11-20 10:06] MAIL FROM Isomer on MacBook: Hello there
        [2026-11-20 10:07] MAIL: [Visor: you have 2 messages in your inbox; read them with read_inbox]
        [2026-11-20 10:08] MAIL TO Isomer on MacBook: Thanks, rebasing.
        [2026-11-20 10:09] MAIL TO 0vgy (send_message): Please rebase onto main
        [2026-11-20 10:10] PERSON: Also bump the version
        [2026-11-20 10:11] PERSON: /goal ship it
        [2026-11-20 10:12] PERSON ANSWERED: Which? → The first
        [2026-11-20 10:13] TASK NOTIFICATION: Background build finished
        [2026-11-20 10:14] TOOL mcp__visor__gh__pr_create: repo=AttilaTheFun/visor base=main title=Super Compact

        """

    private func write(_ lines: [String], partial: String = "") throws -> URL {
        let file = folder.appendingPathComponent("conversation.jsonl")
        try Data((lines.joined(separator: "\n") + "\n" + partial).utf8).write(to: file)
        return file
    }

    private func filtered(_ file: URL, limit: Int? = nil, chunk: Int = 1_000_000, readSize: Int = 4 << 20)
        async throws -> (outcome: SuperCompactFilter.Outcome, chunks: [String]) {
        let out = folder.appendingPathComponent("chunks-" + UUID().uuidString, isDirectory: true)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        let outcome = try await SuperCompactFilter.run(source: file, limit: limit ?? size, into: out, chunkCharacters: chunk, readSize: readSize,
                                                       stop: { false })
        let chunks = try (1...max(outcome.chunks, 1)).prefix(outcome.chunks).map {
            try String(contentsOf: out.appendingPathComponent(SuperCompactFilter.chunkName($0)), encoding: .utf8)
        }
        return (outcome, chunks)
    }

    // MARK: Tests

    /// Every kind of line, read to the golden text: what is kept, in order,
    /// with its time, and nothing that is dropped.
    @Test func everyKindOfLineReadsToTheGoldenText() async throws {
        let (outcome, chunks) = try await filtered(write(Self.lines))
        #expect(outcome.chunks == 1)
        #expect(outcome.lines == Self.lines.count)
        let text = try #require(chunks.first)
        #expect(text == Self.golden, "\(text)")
        for dropped in ["secret thoughts", "subagent words", "PERSON: not this", "iVBORw0KGgo", "output line 5", "boilerplate", "Today's date",
                        "[Image:", "long body"] {
            #expect(!text.contains(dropped), "\(dropped) is dropped")
        }
        #expect(outcome.characters == text.utf8.count)
    }

    /// Read a few bytes at a time — every line longer than a read — it is
    /// the same as read in one piece: the file is streamed, not loaded.
    @Test func theFileIsStreamedAPieceAtATime() async throws {
        let file = try write(Self.lines)
        let whole = try await filtered(file)
        let pieces = try await filtered(file, readSize: 7)
        #expect(pieces.chunks == whole.chunks)
        #expect(pieces.outcome == whole.outcome)
    }

    /// Only the snapshot is read: what the session wrote after the job
    /// began (past `limit`) is not, and a line not ended by it either.
    @Test func onlyTheSnapshotIsRead() async throws {
        let before = Array(Self.lines.prefix(4))
        let snapshot = Data((before.joined(separator: "\n") + "\n").utf8).count
        let half = Self.user("Written after the snapshot", at: "11:00")
        let file = try write(before + [half] + [Self.user("Also after", at: "11:01")])
        let (_, chunks) = try await filtered(file, limit: snapshot + half.utf8.count / 2, readSize: 5)
        #expect(chunks == ["[2026-11-20 09:00] PERSON: Ship 0.64 today. Never force-push.\n"])
        // A line being written at the end of the file is not taken.
        let (_, partial) = try await filtered(try write(before, partial: #"{"type":"user","message":{"content":"half"#))
        #expect(partial == ["[2026-11-20 09:00] PERSON: Ship 0.64 today. Never force-push.\n"])
    }

    /// Chunks hold whole entries, in order, each no larger than the size
    /// (but an entry larger than a chunk, which is one of its own); all of
    /// them together are the text.
    @Test func chunksNeverCutAnEntry() async throws {
        let words = (1...40).map { Self.user("Message number \($0) " + String(repeating: "x", count: $0 * 3), at: String(format: "09:%02d", $0)) }
        let big = Self.user(String(repeating: "y", count: 500), at: "10:00")
        let file = try write(words + [big] + words.prefix(3))
        let (outcome, chunks) = try await filtered(file, chunk: 300)
        let (_, whole) = try await filtered(file)
        #expect(outcome.chunks == chunks.count)
        #expect(chunks.count > 5)
        #expect(chunks.joined() == whole.joined())
        for chunk in chunks {
            let entries = chunk.split(separator: "\n")
            #expect(entries.allSatisfy { $0.hasPrefix("[2026-11-20 ") }, "whole entries: \(chunk)")
            #expect(chunk.utf8.count <= 300 || entries.count == 1, "\(chunk.utf8.count) bytes in \(entries.count) entries")
        }
        #expect(chunks.contains { $0.contains(String(repeating: "y", count: 500)) && $0.split(separator: "\n").count == 1 })
    }

    /// A message longer than the cap is cut, saying how much more there was.
    @Test func aLongMessageIsCapped() throws {
        let text = String(repeating: "z", count: SuperCompactFilter.messageCharacters + 50)
        let entry = try #require(SuperCompactFilter.entry(Data(Self.user(text, at: "09:00").utf8)))
        #expect(entry.hasSuffix(" … [50 more characters cut]"))
        #expect(entry.count < SuperCompactFilter.messageCharacters + 100)
    }
}
}
