// The markers agents' written messages carry (AgentMessageMarkers): read
// from the first line that has words, the computer after the last " on ",
// and nothing without an address and words; written as read.

import VisorProtocol
import XCTest

final class AgentMessageMarkersTests: XCTestCase {
    func testAnOutboundMessageIsReadFromItsFirstLine() {
        let read = AgentMessageMarkers.outbound("\n  @@to Manager on visor-co-tenant  \n\nThe draft is up.\n\nSecond paragraph.\n")
        XCTAssertEqual(read, AgentMessageMarkers.Addressed(session: "Manager", computer: "visor-co-tenant",
                                                           body: "The draft is up.\n\nSecond paragraph."))
    }

    func testTheComputerIsAfterTheLastOn() {
        let read = AgentMessageMarkers.outbound("@@to Work on the site on Logan’s Mac Mini\nHello")
        XCTAssertEqual(read?.session, "Work on the site")
        XCTAssertEqual(read?.computer, "Logan’s Mac Mini")
    }

    func testAReplyThatIsNoMessageIsNone() {
        XCTAssertNil(AgentMessageMarkers.outbound("Done. @@to Manager on mini\nHello"), "not the first line")
        XCTAssertNil(AgentMessageMarkers.outbound("@@to Manager on mini"), "no words")
        XCTAssertNil(AgentMessageMarkers.outbound("@@to Manager\nHello"), "no computer")
        XCTAssertNil(AgentMessageMarkers.outbound("@@from Manager on mini\nHello"), "inbound")
        XCTAssertNil(AgentMessageMarkers.outbound("Just a reply."))
    }

    func testWrittenAsRead() {
        let outbound = AgentMessageMarkers.outboundText(to: "Issues", on: "visor-co-tenant", body: "Labels agreed.")
        XCTAssertEqual(outbound, "@@to Issues on visor-co-tenant\n\nLabels agreed.")
        XCTAssertEqual(AgentMessageMarkers.outbound(outbound)?.body, "Labels agreed.")
        let inbound = AgentMessageMarkers.inboundText(from: "Visor", on: "visor-co-tenant", body: "Thanks.")
        XCTAssertEqual(AgentMessageMarkers.inbound(inbound), AgentMessageMarkers.Addressed(session: "Visor", computer: "visor-co-tenant", body: "Thanks."))
    }
}
