// A Claude session is listed for resuming under the name it goes by now:
// the last title its owner gave it, else the last one Claude wrote, from
// the end of the file — not the words at its start, which may be a hook's
// notice rather than anything the user said.

@testable import VisorServer
import XCTest

final class ResumableTitleTests: ServerTestCase {
    func testTheLatestTitlesAreReadFromTheEnd() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("titles-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        var lines = [#"{"type":"user","message":{"role":"user","content":"A session-scoped Stop hook is now active with condition: ship it"}}"#,
                     #"{"type":"ai-title","aiTitle":"Early-name","sessionId":"s"}"#]
        // More than the window read from the end, so the early title is out of it.
        let filler = #"{"type":"assistant","message":{"content":[{"type":"text","text":""# + String(repeating: "x", count: 10_000) + #""}]}}"#
        lines += Array(repeating: filler, count: 40)
        lines += [#"{"type":"ai-title","aiTitle":"Peer-to-peer-messaging","sessionId":"s"}"#,
                  #"{"type":"custom-title","customTitle":"Convo","sessionId":"s"}"#,
                  #"{"type":"ai-title","aiTitle":"Later-name","sessionId":"s"}"#,
                  #"{"type":"last-prompt","lastPrompt":"hi"}"#]
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let titles = SessionCatalog.titles(atEndOf: file)
        XCTAssertEqual(titles.named, "Convo")
        XCTAssertEqual(titles.written, "Later name")

        // A file with no titles at its end gives none.
        try (lines.prefix(1).joined() + "\n").write(to: file, atomically: true, encoding: .utf8)
        let none = SessionCatalog.titles(atEndOf: file)
        XCTAssertNil(none.named)
        XCTAssertNil(none.written)
    }
}
