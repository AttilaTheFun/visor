// The markers agents' written messages carry (AgentMessageMarkers): read
// from the first line that has words, the computer after the last " on ",
// and nothing without an address and words; written as read.

import VisorProtocol
import Foundation
import Testing

extension ServerTests {
@Suite final class AgentMessageMarkersTests {
    @Test func testAnOutboundMessageIsReadFromItsFirstLine() {
        let read = AgentMessageMarkers.outbound("\n  @@to Manager on visor-co-tenant  \n\nThe draft is up.\n\nSecond paragraph.\n")
        #expect(read == AgentMessageMarkers.Addressed(session: "Manager", computer: "visor-co-tenant",
                                                           body: "The draft is up.\n\nSecond paragraph."))
    }

    @Test func testTheComputerIsAfterTheLastOn() {
        let read = AgentMessageMarkers.outbound("@@to Work on the site on Logan’s Mac Mini\nHello")
        #expect((read?.session) == "Work on the site")
        #expect((read?.computer) == "Logan’s Mac Mini")
    }

    @Test func testAReplyThatIsNoMessageIsNone() {
        #expect(AgentMessageMarkers.outbound("Done. @@to Manager on mini\nHello") == nil, "not the first line")
        #expect(AgentMessageMarkers.outbound("@@to Manager on mini") == nil, "no words")
        #expect(AgentMessageMarkers.outbound("@@to Manager\nHello") == nil, "no computer")
        #expect(AgentMessageMarkers.outbound("@@from Manager on mini\nHello") == nil, "inbound")
        #expect(AgentMessageMarkers.outbound("Just a reply.") == nil)
    }

    @Test func testWrittenAsRead() {
        let outbound = AgentMessageMarkers.outboundText(to: "Issues", on: "visor-co-tenant", body: "Labels agreed.")
        #expect(outbound == "@@to Issues on visor-co-tenant\n\nLabels agreed.")
        #expect((AgentMessageMarkers.outbound(outbound)?.body) == "Labels agreed.")
        let inbound = AgentMessageMarkers.inboundText(from: "Visor", on: "visor-co-tenant", body: "Thanks.")
        #expect(AgentMessageMarkers.inbound(inbound) == AgentMessageMarkers.Addressed(session: "Visor", computer: "visor-co-tenant", body: "Thanks."))
    }
}
}
