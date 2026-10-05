// Numbers off the wire never trap, whatever they are, and a count of
// tokens is whole past what 32 bits hold: on the web `Int` is 32 bits,
// and a session whose usage passed two billion tokens took the client
// down as its list of sessions was decoded.

@testable import VisorClient
import VisorProtocol
import XCTest

final class WireNumbersTests: XCTestCase {
    /// As a 32-bit `Int` would take them (`Int32` here, on a 64-bit Mac):
    /// the whole part where it fits, the nearest end past it, 0 for what
    /// is not a number.
    func testAWholeNumberIsTakenWithoutTrapping() {
        XCTAssertEqual(Int32(whole: 1_999.9), 1_999)
        XCTAssertEqual(Int32(whole: -3.7), -3)
        XCTAssertEqual(Int32(whole: 3_302_964_500), .max)
        XCTAssertEqual(Int32(whole: -3_302_964_500), .min)
        XCTAssertEqual(Int32(whole: .infinity), .max)
        XCTAssertEqual(Int32(whole: -.infinity), .min)
        XCTAssertEqual(Int32(whole: .nan), 0)
        XCTAssertEqual(Int64(whole: 3_302_964_500), 3_302_964_500)
        XCTAssertEqual(Int64(whole: 1e300), .max)
        XCTAssertEqual(Int64(whole: 9_223_372_036_854_775_808), .max, "2^63 is one past the end")
        XCTAssertEqual(parseJSON("1e300")?.int, .max)
        XCTAssertEqual(parseJSON("-1e300")?.int64, .min)
    }

    /// A session with more than 2^31 tokens used, through JSON and back.
    func testASessionsUsagePastTwoBillionTokens() throws {
        var info = SessionInfo(id: "s", agent: .claude, cwd: "/tmp", title: "Long", created: 0)
        info.usage = SessionUsage(input: 3_302_964_500, cached: 3_100_000_000, output: 12_000_000, cost: 812.4)
        let list = try XCTUnwrap(Envelope.decode(Envelope.sessions([info]).encoded())?.sessions)
        XCTAssertEqual(list.first?.usage, info.usage)
        // And numbers no count should be: taken, not trapped on.
        let odd = #"{"type":"sessions","sessions":[{"id":"s","agent":"claude","cwd":"/","title":"t","contextUsed":1e40,"contextLimit":-1e40,"# +
            #""usage":{"input":1e40,"cached":-5,"output":2.9},"mode":{"kind":"tui","controller":"c","cols":1e12,"rows":1e12}}],"revision":1e30,"cols":1e30}"#
        let taken = try XCTUnwrap(Envelope.decode(odd))
        XCTAssertEqual(taken.sessions?.first?.usage?.input, .max)
        XCTAssertEqual(taken.sessions?.first?.usage?.output, 2)
        XCTAssertEqual(taken.sessions?.first?.contextUsed, .max)
        XCTAssertEqual(taken.revision, .max)
    }

    /// The canned computer answers through the wire's coding, with a count
    /// past 2^31 in it: a screenshot of the fixture on any platform is a
    /// run of the decoders on that platform.
    @MainActor func testTheFixtureGoesOverTheWire() throws {
        let welcome = FixtureAgentServer.welcome
        let chat = try XCTUnwrap(welcome.sessions?.first { $0.id == VisorFixture.chatSession })
        XCTAssertGreaterThan(try XCTUnwrap(chat.usage).input, Int64(Int32.max))
        XCTAssertEqual(welcome.sessions, VisorFixture.sessions, "nothing is lost on the way")
        XCTAssertEqual(welcome.catalogs?.map(\.agent), VisorFixture.catalogs.map(\.agent))
        XCTAssertEqual(welcome.catalogs?.first?.account?.limits.map(\.name), ["5-hour", "Weekly"])
    }
}
