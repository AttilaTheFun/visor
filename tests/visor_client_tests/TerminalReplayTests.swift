// A terminal session's bytes on the client: live chunks are added to what
// the view was given; a replay of the whole screen (this window took the
// terminal, or subscribed again) replaces it, and tells the view to start
// its screen over.

@testable import VisorClient
import VisorProtocol
import XCTest

@MainActor
final class TerminalReplayTests: XCTestCase {
    func testAReplayStartsTheScreenOver() {
        let transcript = SessionTranscript()
        var told: [(String, Bool)] = []
        transcript.onTerminalBytes = { chunk, startsOver in told.append((chunk, startsOver)) }

        transcript.apply(.tty(session: "T", data: "YQ=="))
        transcript.apply(.tty(session: "T", data: "Yg=="))
        XCTAssertEqual(transcript.terminalBacklog, ["YQ==", "Yg=="])

        var replay = Envelope.tty(session: "T", data: "Yw==")
        replay.cols = 80
        replay.rows = 24
        transcript.apply(replay)
        XCTAssertEqual(transcript.terminalBacklog, ["Yw=="], "the replay stands in for what was kept")

        // A shell that has drawn nothing yet still starts the screen over.
        var empty = Envelope.tty(session: "T", data: "")
        empty.cols = 80
        empty.rows = 24
        transcript.apply(empty)
        XCTAssertEqual(transcript.terminalBacklog, [""])
        // A live chunk with nothing in it is no news.
        transcript.apply(.tty(session: "T", data: ""))

        XCTAssertEqual(told.map(\.1), [false, false, true, true])
    }
}
