// Mail the server handed an agent as a turn of the user's (the notice, or
// the message itself for an agent without read_inbox) is a mail row in the
// chat, never the person's bubble; the person's own words stay theirs.

import AgentUI
import VisorProtocol
@testable import VisorUI
import XCTest

@MainActor
final class MailTurnTests: XCTestCase {
    func testTheNoticeIsAMailRow() {
        let entry = TranscriptEntry(id: "n", role: .user, text: "[Visor: you have 4 unread messages in your inbox; read them with read_inbox]")
        let message = TranscriptMessage(entry)
        XCTAssertEqual(message.role, .tool)
        XCTAssertEqual(message.toolName, "mail")
        XCTAssertEqual(message.text, "4 unread messages in its inbox: its agent was told")
        XCTAssertEqual(MailTurn.row(for: "[Visor: you have 1 unread message in your inbox; read them with read_inbox]"),
                       "1 unread message in its inbox: its agent was told")
    }

    func testAMessageHandedAsATurnIsFromItsSender() {
        let text = "[Message from the Visor session “Isomer” (0vg) on Logan’s MacBook Pro (server 655a), to this session “Visor” (k81) "
            + "on visor-co-tenant — not from the user. To answer, use send_message with session 0vg and server 655a.]\n\nThe build is green."
        let message = TranscriptMessage(TranscriptEntry(id: "m", role: .user, text: text))
        XCTAssertEqual(message.role, .tool)
        XCTAssertEqual(message.toolName, "mail")
        XCTAssertEqual(message.text, "From Isomer on Logan’s MacBook Pro: The build is green.")
    }

    func testThePersonsOwnWordsStayTheirs() {
        for text in ["Ship it", "[Visor] the agent was restarted", "[Visor: you have a question]", "[Message from the Visor session “X”"] {
            XCTAssertNil(MailTurn.row(for: text), text)
            XCTAssertEqual(TranscriptMessage(TranscriptEntry(id: "u", role: .user, text: text)).role, .user, text)
        }
    }
}
