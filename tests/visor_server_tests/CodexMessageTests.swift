// Codex's words reach the session as they stream, or whole when its
// message completes: a message Codex sent only whole is shown once, and a
// streamed one is not shown again when it completes.

import Foundation
@testable import VisorServer
import XCTest

@MainActor
final class CodexMessageTests: ServerTestCase {
    func testACompletedMessageCarriesItsWords() {
        let line = #"{"method":"item/completed","params":{"threadId":"t","turnId":"u","item":{"type":"agentMessage","id":"m1","text":"All done."}}}"#
        let outputs = CodexOutput.parse(line)
        XCTAssertEqual(outputs.count, 2)
        guard case .messageCompleted(let item, let text)? = outputs.first else { return XCTFail("no message") }
        XCTAssertEqual(item, "m1")
        XCTAssertEqual(text, "All done.")
        guard case .itemCompleted(let id, false)? = outputs.last else { return XCTFail("not completed") }
        XCTAssertEqual(id, "m1")
    }

    func testAWholeMessageIsShownOnceAndAStreamedOneNotAgain() async {
        let process = CodexAppServerProcess(cwd: "/tmp", skipPermissions: true, resume: nil)
        // Sent only whole: shown as it completes.
        process.say(item: "a", text: "Whole.", whole: true)
        // Streamed, then completed with the same words: shown once.
        process.say(item: "b", text: "Stre", whole: false)
        process.say(item: "b", text: "amed.", whole: false)
        process.say(item: "b", text: "Streamed.", whole: true)
        // The next message, to read up to.
        process.say(item: "c", text: "Next.", whole: true)
        var said: [String] = []
        for await event in process.events {
            guard case .delta(let message, let text) = event else { continue }
            said.append("\(message): \(text)")
            if message == "c" { break }
        }
        XCTAssertEqual(said, ["a: Whole.", "b: Stre", "b: amed.", "c: Next."])
    }
}
